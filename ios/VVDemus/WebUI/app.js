// Identifies this tab to the phone. Kept in sessionStorage rather than a plain variable
// so it survives a reload: the phone records which client owns "This Computer", and a
// reloaded tab that still has the same id silently reclaims casting. Without this, any
// reload (or navigating away and back) left the phone casting to a tab that no longer
// considered itself the cast tab — no audio anywhere, progress frozen, and no fallback
// either, since a socket was still connected.
const CLIENT_ID = (() => {
  let id = sessionStorage.getItem("vvdemus_client_id");
  if (!id) {
    id = Math.random().toString(36).slice(2) + Date.now().toString(36);
    sessionStorage.setItem("vvdemus_client_id", id);
  }
  return id;
})();

const state = {
  current: null,
  likedIds: new Set(),
  // True only for the tab the phone currently names as the cast client. Derived from
  // every state snapshot rather than set once on click, so a tab that loses ownership
  // (another tab took over, or the phone was picked) stops producing sound on its own —
  // two tabs both believing they were casting used to play the same track twice, and
  // fire two /api/next calls at the end of it.
  isCastTab: false,
  loadedVideoId: null,
  loadedTrackEpoch: null,
  lastReportAt: 0,
  // Set when the browser refuses a programmatic play() for lack of a user gesture (the
  // reclaim-after-reload case); cleared once any click lets us try again.
  needsGesture: false,
  last: null,
  // Last known queue/liked contents, kept so broadcasts that omit them (because they
  // haven't changed) can be filled back in — see mergeOmittedQueues.
  lastQueues: {},
  // Latest playback epoch seen from the phone; echoed back with progress reports.
  epoch: null,
  failedSrc: null,
  failedAt: 0,
  // What the phone says plays next, with a resolved URL — this tab's lifeline if the
  // phone goes away mid-song.
  upNext: null,
  // Set when this tab advanced on its own because the phone was unreachable; cleared once
  // the phone has accepted our account of what's playing.
  playedWhileDisconnected: null,
  reconcileAttempts: 0,
  reconciling: false,
};

const audioEl = document.getElementById("np-audio");

// The track list + header info currently shown in the generic detail view
// (playlist / radio / daylist / liked / downloads) — Play/Shuffle/Refresh act on this.
let detail = { tracks: [], title: "", kind: null, seedTrack: null };

const ICONS = {
  heartOutline:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 21s-7.5-4.6-10-9.2C.4 8.6 2 5 5.6 5 8 5 9.6 6.3 12 8.8 14.4 6.3 16 5 18.4 5 22 5 23.6 8.6 22 11.8 19.5 16.4 12 21 12 21z"/></svg>',
  heartFilled:
    '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 21s-7.5-4.6-10-9.2C.4 8.6 2 5 5.6 5 8 5 9.6 6.3 12 8.8 14.4 6.3 16 5 18.4 5 22 5 23.6 8.6 22 11.8 19.5 16.4 12 21 12 21z"/></svg>',
  add: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M11 5h2v6h6v2h-6v6h-2v-6H5v-2h6z"/></svg>',
  remove:
    '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M6.4 5 5 6.4 10.6 12 5 17.6 6.4 19 12 13.4 17.6 19 19 17.6 13.4 12 19 6.4 17.6 5 12 10.6z"/></svg>',
  note: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M9 18V5l11-2v13M9 18a3 3 0 1 1-6 0 3 3 0 0 1 6 0zm11-2a3 3 0 1 1-6 0 3 3 0 0 1 6 0z" fill="none" stroke="currentColor" stroke-width="1.6"/></svg>',
};

// ---------- helpers ----------

function fmtTime(seconds) {
  if (!isFinite(seconds) || seconds < 0) return "0:00";
  const s = Math.floor(seconds);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

async function api(path, options) {
  const res = await fetch(path, options);
  if (!res.ok) throw new Error(`${path} -> ${res.status}`);
  const contentType = res.headers.get("content-type") || "";
  return contentType.includes("application/json") ? res.json() : res.text();
}

function post(path, body) {
  return api(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body ?? {}),
  });
}

function escapeHtml(text) {
  const div = document.createElement("div");
  div.textContent = text;
  return div.innerHTML;
}

/// YouTube hands back thumbnail URLs at whatever size it picked — usually 544px square,
/// ~50KB each — and this page was rendering them into 32-56px slots. A full page of
/// results cost nearly 2MB of artwork to display a few hundred KB worth of pixels. The
/// `=w{N}-h{N}` suffix in the URL is a server-side resize (the iOS app relies on the same
/// trick), so ask for what's actually going to be drawn.
function art(url, cssPixels) {
  if (!url) return "";
  const match = /=w(\d+)-h\d+/.exec(url);
  if (!match) return url;
  // Capped at 2x: beyond that the extra bytes buy nothing visible on any real display.
  const wanted = Math.ceil(cssPixels * Math.min(window.devicePixelRatio || 1, 2));
  // Never ask for more than the URL already offers. These come back at wildly different
  // sizes depending on the endpoint (search gives 120px, radio gives 544px), and asking a
  // 120px source for 340px doesn't add detail — it upscales server-side and costs six
  // times the bytes.
  const target = Math.min(wanted, Number(match[1]));
  return url.replace(/=w\d+-h\d+/, `=w${target}-h${target}`);
}

// ---------- view switching ----------

function showView(name) {
  document.querySelectorAll(".view").forEach((v) => v.classList.remove("active"));
  document.getElementById(`view-${name}`).classList.add("active");
  document.querySelectorAll(".nav-item").forEach((b) => b.classList.remove("active"));
  document.querySelectorAll(".lib-shortcut, .library-row").forEach((b) => b.classList.remove("active"));
}

document.querySelectorAll(".nav-item").forEach((btn) => {
  btn.onclick = () => {
    showView(btn.dataset.view);
    btn.classList.add("active");
    if (btn.dataset.view === "search") document.getElementById("global-search").focus();
  };
});

document.getElementById("open-queue").onclick = () => showView("queue");

// ---------- track row rendering ----------

function trackRow(track, { onPlay, showRemove, onRemove } = {}) {
  const row = document.createElement("div");
  row.className = "track-row" + (state.current && state.current.videoId === track.videoId ? " active" : "");

  const img = document.createElement("img");
  img.src = art(track.thumbnailUrl, 44); // .track-row img is 44px
  row.appendChild(img);

  const meta = document.createElement("div");
  meta.className = "track-meta";
  const title = document.createElement("div");
  title.className = "track-title";
  title.textContent = track.title;
  const artist = document.createElement("div");
  artist.className = "track-artist";
  artist.textContent = track.artist;
  meta.appendChild(title);
  meta.appendChild(artist);
  row.appendChild(meta);

  const actions = document.createElement("div");
  actions.className = "row-actions";

  const likeBtn = document.createElement("button");
  likeBtn.innerHTML = state.likedIds.has(track.videoId) ? ICONS.heartFilled : ICONS.heartOutline;
  likeBtn.title = "Like";
  if (state.likedIds.has(track.videoId)) likeBtn.classList.add("liked");
  likeBtn.onclick = async (e) => {
    e.stopPropagation();
    await post("/api/library/liked/toggle", { track });
    refreshState();
  };
  actions.appendChild(likeBtn);

  const queueBtn = document.createElement("button");
  queueBtn.innerHTML = ICONS.add;
  queueBtn.title = "Add to queue";
  queueBtn.onclick = async (e) => {
    e.stopPropagation();
    await post("/api/queue/add", { track });
  };
  actions.appendChild(queueBtn);

  if (showRemove) {
    const removeBtn = document.createElement("button");
    removeBtn.innerHTML = ICONS.remove;
    removeBtn.title = "Remove";
    removeBtn.onclick = async (e) => {
      e.stopPropagation();
      await onRemove(track);
    };
    actions.appendChild(removeBtn);
  }

  row.appendChild(actions);
  row.onclick = () => onPlay && onPlay(track);
  return row;
}

/// Everything a rendered row actually displays: the tracks themselves, which one is
/// playing, and which are liked. If none of that moved, the existing DOM is already
/// correct.
/// `scope` distinguishes two different screens that happen to hold the same tracks — the
/// rows would look identical, but their click handlers are bound to different contexts
/// (which playlist a track was played "from"), so reusing the DOM across them would play
/// the right song from the wrong list.
function listSignature(tracks, scope) {
  const current = state.current ? state.current.videoId : "";
  return (
    (scope || "") +
    "|" +
    current +
    "|" +
    (tracks || []).map((t) => t.videoId + (state.likedIds.has(t.videoId) ? "1" : "0")).join(",")
  );
}

/// Skips the rebuild when nothing changed. The queue lists are re-rendered from every
/// state broadcast — once a second — and blowing away `innerHTML` each time meant the
/// queue you were reading was destroyed and recreated under the cursor five times a
/// second: scroll position jumped, hover states flickered, and a click could land on a
/// row that no longer existed by the time it registered.
function renderList(container, tracks, opts) {
  const signature = listSignature(tracks, opts && opts.scope);
  if (container.dataset.sig === signature) return;
  container.dataset.sig = signature;

  container.innerHTML = "";
  if (!tracks || tracks.length === 0) {
    const empty = document.createElement("div");
    empty.className = "empty-hint";
    empty.textContent = "Nothing here yet.";
    container.appendChild(empty);
    return;
  }
  tracks.forEach((t) => container.appendChild(trackRow(t, opts)));
}

// ---------- generic detail view (playlist / radio / daylist / liked / downloads) ----------

function openDetail(tracks, { title, subtitle, badge, imageURL, kind, seedTrack, showRefresh }) {
  detail = { tracks, title, kind: kind || null, seedTrack: seedTrack || null };

  document.getElementById("detail-badge").textContent = badge || "";
  document.getElementById("detail-title").textContent = title;
  document.getElementById("detail-subtitle").textContent = subtitle || "";
  document.getElementById("detail-art").innerHTML = imageURL ? `<img src="${imageURL}" alt="">` : "";
  document.getElementById("detail-refresh").style.display = showRefresh ? "flex" : "none";

  renderList(document.getElementById("detail-list"), tracks, {
    scope: `${kind || "detail"}:${title}`,
    onPlay: (t) => post("/api/play", { track: t, context: tracks, contextTitle: title }).then(refreshState),
  });
  showView("detail");
}

document.getElementById("detail-play").onclick = () => {
  if (!detail.tracks.length) return;
  post("/api/play", { track: detail.tracks[0], context: detail.tracks, contextTitle: detail.title }).then(refreshState);
};

document.getElementById("detail-shuffle").onclick = () => {
  if (!detail.tracks.length) return;
  const shuffled = [...detail.tracks].sort(() => Math.random() - 0.5);
  post("/api/play", { track: shuffled[0], context: shuffled, contextTitle: detail.title }).then(refreshState);
};

document.getElementById("detail-refresh").onclick = async () => {
  if (detail.kind === "radio" && detail.seedTrack) {
    const tracks = await post("/api/radio/refresh", { videoId: detail.seedTrack.videoId });
    openRadioDetail(detail.seedTrack, tracks);
  } else if (detail.kind === "daylist") {
    await post("/api/library/daylist/refresh");
    await openDaylistDetail();
  }
};

function radioSubtitle(seedTrack, tracks) {
  const others = tracks
    .filter((t) => t.videoId !== seedTrack.videoId)
    .map((t) => t.artist)
    .flatMap((a) => a.split(", "));
  const seen = new Set();
  const unique = others.filter((a) => (seen.has(a) ? false : (seen.add(a), true))).slice(0, 3);
  return unique.length ? `With ${unique.join(", ")} and more` : "";
}

function openRadioDetail(seedTrack, tracks) {
  openDetail(tracks, {
    title: `${seedTrack.title} Radio`,
    subtitle: radioSubtitle(seedTrack, tracks),
    badge: "Radio",
    imageURL: art(seedTrack.thumbnailUrl, 180),
    kind: "radio",
    seedTrack,
    showRefresh: true,
  });
}

async function openDaylistDetail() {
  const daylist = await api("/api/library/daylist");
  openDetail(daylist.tracks, {
    title: daylist.title || "Daylist",
    subtitle: `${daylist.tracks.length} songs`,
    badge: "Made for you",
    imageURL: daylist.tracks[0] ? art(daylist.tracks[0].thumbnailUrl, 180) : null,
    kind: "daylist",
    showRefresh: true,
  });
}

async function openPlaylistDetail(playlist) {
  openDetail(playlist.tracks, {
    title: playlist.name,
    subtitle: `${playlist.tracks.length} songs`,
    badge: "Playlist",
    imageURL: playlist.tracks[0] ? art(playlist.tracks[0].thumbnailUrl, 180) : null,
    kind: "playlist",
  });
}

async function openLikedDetail() {
  const tracks = await api("/api/library/liked");
  openDetail(tracks, {
    title: "Liked Songs",
    subtitle: `${tracks.length} songs`,
    badge: "Playlist",
    kind: "liked",
  });
}

async function openDownloadsDetail() {
  const tracks = await api("/api/library/downloads");
  openDetail(tracks, {
    title: "Downloads",
    subtitle: `${tracks.length} songs`,
    badge: "Offline",
    kind: "downloads",
  });
}

document.querySelectorAll(".lib-shortcut").forEach((btn) => {
  btn.onclick = async () => {
    document.querySelectorAll(".lib-shortcut, .library-row, .nav-item").forEach((b) => b.classList.remove("active"));
    btn.classList.add("active");
    const which = btn.dataset.detail;
    if (which === "daylist") await openDaylistDetail();
    else if (which === "liked") await openLikedDetail();
    else if (which === "downloads") await openDownloadsDetail();
  };
});

// ---------- device switching (VVDemus Connect) ----------

document.getElementById("np-device-btn").onclick = (e) => {
  e.stopPropagation();
  document.getElementById("np-device-menu").classList.toggle("open");
};
document.addEventListener("click", () => {
  document.getElementById("np-device-menu").classList.remove("open");
});
// A single silent-frame WAV, used only to "unlock" the audio element synchronously
// inside the click handler below. Browsers only allow an <audio> element to
// autoplay/programmatically play if that permission was earned by a play() call made as
// a direct, synchronous result of a user gesture — a play() call made later (after even
// one `await`, e.g. waiting on the /api/device POST or the follow-up state fetch) is
// treated as unrelated to the click and silently blocked. Playing this tiny clip right
// in the click handler earns that permission for the *element*, so swapping its `src` to
// the real track a moment later (once the server has resolved it) and calling play()
// again keeps working without needing a fresh gesture each time.
const SILENT_UNLOCK_SRC =
  "data:audio/wav;base64,UklGRiQAAABXQVZFZm10IBAAAAABAAEARKwAAIhYAQACABAAZGF0YQAAAAA=";

// The unlock clip has zero audio samples, so it fires `ended` almost immediately after
// play() — misreading that as the *real* track finishing was what caused an unwanted
// /api/next (changing the song right when switching to "computer"). A boolean flag to
// tell the two apart turned out to still be timing-dependent: whether the flag had
// already been cleared (by the real track loading) depended on which happened first,
// the flag clear or the clip's `ended` finally firing — and that race could go either
// way. Instead, the "next track" listener is only ever *attached* once a real track is
// loaded, and detached right before the unlock clip plays — so the clip's `ended` event
// has nothing listening for it at all, regardless of exactly when it fires.
/// End of a real track while this tab is casting.
///
/// Normally the phone decides what plays next. But if it's asleep, off the network, or
/// otherwise unreachable at this exact moment, that request fails and the music simply
/// stops — which is why playback used to die *between* songs rather than during one.
/// So: ask the phone first, and if it doesn't answer, play the track it already told us
/// was coming (`upNext`, sent with its stream URL resolved ahead of time) and reconcile
/// once the phone is back.
async function handleRealTrackEnded() {
  if (!state.isCastTab) return;
  try {
    await post("/api/next");
    refreshState();
  } catch (e) {
    playUpNextLocally();
  }
}

function playUpNextLocally() {
  const next = state.upNext;
  if (!next || !next.track || !next.streamUrl) {
    // Nothing prefetched — the queue ran out, or the phone dropped before it could tell
    // us. Genuinely nothing to play; the phone will resync when it returns.
    return;
  }
  audioEl.src = next.streamUrl;
  audioEl.load();
  state.loadedVideoId = next.track.videoId;
  state.loadedTrackEpoch = null; // no longer tracking the phone's load generation
  state.upNext = null;
  // Remembered so the phone can be told what really happened once it answers again.
  state.playedWhileDisconnected = next.track.videoId;
  audioEl.addEventListener("ended", handleRealTrackEnded);
  playCastAudio();
  renderDeviceLabel();
}

/// Tells the phone what this tab is actually playing after having moved on without it.
/// Until the phone accepts it, incoming state is not allowed to reload the audio element
/// — otherwise the phone's stale idea of the current track would yank the browser back to
/// a song it finished minutes ago.
async function reconcileAfterDisconnection() {
  if (!state.playedWhileDisconnected || state.reconciling) return;
  state.reconciling = true;
  try {
    await post("/api/playback/adopt", {
      videoId: state.playedWhileDisconnected,
      progress: audioEl.currentTime || 0,
      clientId: CLIENT_ID,
    });
    state.playedWhileDisconnected = null;
    state.reconcileAttempts = 0;
    refreshState();
  } catch (e) {
    // Still unreachable. Keep playing and retry on the next state that gets through, but
    // don't hold this tab out of sync forever if the phone simply won't have it.
    state.reconcileAttempts = (state.reconcileAttempts || 0) + 1;
    if (state.reconcileAttempts > 8) {
      state.playedWhileDisconnected = null;
      state.reconcileAttempts = 0;
    }
  } finally {
    state.reconciling = false;
  }
}

/// Fully lets go of whatever the element was playing. `removeAttribute("src")` alone does
/// *not* do this — the already-selected resource stays loaded and playable, so a later
/// play() (notably the silent-clip unlock when casting is picked back up) would resume the
/// old audio for a moment and report it to the phone as though it were the current track.
/// `load()` runs the resource selection algorithm again on an empty src, which aborts it.
function releaseAudioElement() {
  audioEl.pause();
  audioEl.removeAttribute("src");
  audioEl.load();
  state.loadedVideoId = null;
  state.loadedTrackEpoch = null;
}

function unlockAudioElementForGesture() {
  try {
    audioEl.removeEventListener("ended", handleRealTrackEnded);
    audioEl.src = SILENT_UNLOCK_SRC;
    const p = audioEl.play();
    if (p && p.catch) p.catch(() => {});
  } catch (e) {
    /* ignore — worst case the later real play() attempt is blocked and silent */
  }
}

document.querySelectorAll("#np-device-menu button").forEach((btn) => {
  btn.onclick = async (e) => {
    e.stopPropagation();
    document.getElementById("np-device-menu").classList.remove("open");
    const device = btn.dataset.device;
    state.isCastTab = device === "computer";
    state.needsGesture = false;
    if (state.isCastTab) {
      unlockAudioElementForGesture();
    } else {
      releaseAudioElement();
    }
    // clientId is what makes the phone able to name *this* tab as the cast client.
    await post("/api/device", { device, clientId: CLIENT_ID });
    refreshState();
  };
});

/// play() is rejected when the browser hasn't been given a user gesture for this element
/// — which is exactly the situation after reclaiming casting on page load. Rather than
/// failing silently, arm a one-shot retry on the next click anywhere and say so in the
/// device label.
function playCastAudio() {
  const p = audioEl.play();
  if (p && p.catch) p.catch(() => armGestureRetry());
}

function armGestureRetry() {
  if (state.needsGesture) return;
  state.needsGesture = true;
  renderDeviceLabel();
  const retry = () => {
    document.removeEventListener("pointerdown", retry, true);
    state.needsGesture = false;
    renderDeviceLabel();
    if (state.isCastTab && audioEl.getAttribute("src")) playCastAudio();
  };
  document.addEventListener("pointerdown", retry, true);
}

function renderDeviceLabel() {
  const s = state.last;
  const label = document.getElementById("np-device-label");
  if (!s || s.activeDevice !== "computer") {
    label.textContent = "Playing on iPhone";
  } else if (!state.isCastTab) {
    label.textContent = "Playing on another computer";
  } else if (state.playedWhileDisconnected) {
    label.textContent = "Playing on This Computer (phone offline)";
  } else if (state.needsGesture) {
    label.textContent = "Click anywhere to resume";
  } else {
    label.textContent = "Playing on This Computer";
  }
}

/// Keeps this tab's <audio> element in sync with the server's playback state whenever
/// this tab is the one that actually chose "This Computer" — a no-op for every other tab
/// (or when the phone is the active device), and idempotent so it can be called from the
/// periodic state broadcast, an explicit refresh, and a pushed "command" message alike
/// without ever double-applying a play/pause toggle.
function syncCastAudio(s) {
  const videoId = s.currentTrack ? s.currentTrack.videoId : null;
  // Ownership comes from the phone, not from whatever this tab last clicked — that's what
  // lets a reloaded tab pick casting back up, and what makes a tab that lost ownership
  // shut up instead of playing over the tab that took it.
  state.isCastTab = s.activeDevice === "computer" && !!s.castClientId && s.castClientId === CLIENT_ID;

  if (!state.isCastTab || !videoId) {
    // If this tab kept playing through an outage, don't go quiet just because the phone
    // gave up on us and took playback back — it did that believing we had stopped. Ask
    // for it back first; only fall silent if the phone refuses.
    if (state.playedWhileDisconnected) {
      reconcileAfterDisconnection();
      return;
    }
    if (state.loadedVideoId) releaseAudioElement();
    return;
  }
  // A changed trackLoadEpoch with an unchanged videoId means the phone restarted the
  // track that's already playing — the computer has to start over too, or the two sit at
  // visibly different positions in the same song.
  // We got ahead of the phone while it was away. Until it accepts what we're actually
  // playing, its idea of the current track is out of date — reloading from it here would
  // interrupt real audio to go back to a finished song. The device making the sound wins.
  if (state.playedWhileDisconnected) {
    reconcileAfterDisconnection();
    return;
  }
  if (state.loadedVideoId !== videoId || state.loadedTrackEpoch !== s.trackLoadEpoch) {
    // The phone resolves streamUrl asynchronously after a device switch (or a new track
    // starting), so a snapshot can name the new track while streamUrl is still empty —
    // or, worse, still holds the *previous* track's URL. `streamVideoId` says which track
    // the URL was resolved for; anything else means "not ready yet", and loading it would
    // leave this computer playing one track behind the phone with nothing to correct it.
    if (!s.streamUrl || s.streamVideoId !== videoId) return;
    // Don't hammer a URL that just failed to load; let the next track (or a re-resolve
    // after a device switch) get a fresh one instead of retrying every broadcast tick.
    if (s.streamUrl === state.failedSrc && Date.now() - state.failedAt < 5000) return;
    audioEl.src = s.streamUrl;
    // Explicit, because re-assigning the *same* URL (the restart-current-track case) is
    // not guaranteed to start the media load algorithm over on its own.
    audioEl.load();
    audioEl.currentTime = s.progress || 0;
    state.loadedVideoId = videoId;
    state.loadedTrackEpoch = s.trackLoadEpoch;
    // Idempotent — the DOM ignores adding the exact same listener function twice — so
    // it's safe to call this on every real-track load rather than tracking separately
    // whether it's already attached.
    audioEl.addEventListener("ended", handleRealTrackEnded);
  }
  if (s.isPlaying && audioEl.paused) playCastAudio();
  if (!s.isPlaying && !audioEl.paused) audioEl.pause();
}

audioEl.addEventListener("error", () => {
  // Lets the next state sync retry the load (e.g. a transiently expired/failed stream
  // URL) instead of leaving this videoId permanently marked "loaded" with nothing
  // actually playing. The URL that failed is remembered so the retry is throttled rather
  // than firing on every broadcast tick.
  if (!state.isCastTab) return;
  state.failedSrc = audioEl.getAttribute("src");
  state.failedAt = Date.now();
  state.loadedVideoId = null;
});

audioEl.addEventListener("timeupdate", () => {
  // No loaded track means there's nothing meaningful to report — and an untagged report
  // is one the phone will (correctly) throw away anyway.
  if (!state.isCastTab || !state.loadedVideoId || audioEl.currentSrc === SILENT_UNLOCK_SRC) return;
  // Swapping `src` for a new track doesn't reset the element instantly: for a moment
  // `loadedVideoId` is already the new track while `currentTime` still reads the old
  // resource's position. Reporting that pairing told the phone the new track was already
  // N seconds in, and the phone then handed that back as the position to resume from —
  // so the track started N seconds late. readyState drops to HAVE_NOTHING during the
  // swap, which is precisely the window to stay quiet through.
  if (audioEl.readyState < 1) return;
  const now = Date.now();
  if (now - state.lastReportAt < 900) return;
  state.lastReportAt = now;
  post("/api/playback/report", {
    // Tagged so the phone can discard reports about a track it has already moved on from,
    // or about playback as it was before its latest instruction (see playbackEpoch).
    videoId: state.loadedVideoId,
    epoch: state.epoch,
    progress: audioEl.currentTime,
    duration: isFinite(audioEl.duration) ? audioEl.duration : 0,
    isPlaying: !audioEl.paused,
  });
});

// ---------- now playing ----------

function renderNowPlaying(s) {
  mergeOmittedQueues(s);
  state.upNext = s.nextTrack && s.nextStreamUrl ? { track: s.nextTrack, streamUrl: s.nextStreamUrl } : null;
  state.current = s.currentTrack;
  state.last = s;
  state.epoch = s.playbackEpoch;
  syncCastAudio(s); // sets state.isCastTab, which the label depends on
  renderDeviceLabel();
  const npArt = document.getElementById("np-art");
  npArt.src = s.currentTrack ? art(s.currentTrack.thumbnailUrl, 56) : "";
  // The phone resolving a stream can take a second or two; without any sign of it, the
  // remote just looked frozen between pressing play and hearing anything.
  npArt.classList.toggle("loading", !!s.isLoading);
  document.getElementById("np-title").textContent = s.currentTrack ? s.currentTrack.title : "Nothing playing";
  document.getElementById("np-artist").textContent = s.currentTrack ? s.currentTrack.artist : "";
  document.getElementById("np-play-icon").style.display = s.isPlaying ? "none" : "block";
  document.getElementById("np-pause-icon").style.display = s.isPlaying ? "block" : "none";
  document.getElementById("np-shuffle").classList.toggle("active", !!s.isShuffling);

  const likeBtn = document.getElementById("np-like");
  const liked = s.currentTrack && (s.likedVideoIds || []).includes(s.currentTrack.videoId);
  likeBtn.innerHTML = liked ? ICONS.heartFilled : ICONS.heartOutline;
  likeBtn.classList.toggle("liked", !!liked);

  const seek = document.getElementById("np-seek");
  if (!seek.dragging) {
    seek.max = Math.max(s.duration, 1);
    seek.value = s.progress;
  }
  document.getElementById("np-elapsed").textContent = fmtTime(s.progress);
  document.getElementById("np-duration").textContent = fmtTime(s.duration);

  state.likedIds = new Set(s.likedVideoIds || []);

  renderList(document.getElementById("manual-queue-list"), s.manualQueue, {
    onPlay: (t) => post("/api/queue/skip-to", { track: t }),
    showRemove: true,
    onRemove: (t) => post("/api/queue/remove", { track: t }),
  });
  document.getElementById("context-queue-title").textContent = s.queueContextTitle
    ? `Next from: ${s.queueContextTitle}`
    : "Next Up";
  renderList(document.getElementById("context-queue-list"), s.contextQueue, {
    onPlay: (t) => post("/api/queue/skip-to", { track: t }),
    showRemove: true,
    onRemove: (t) => post("/api/queue/remove", { track: t }),
  });
}

/// The phone leaves the queue and liked list out of a periodic broadcast when they haven't
/// changed (they're most of a snapshot's size and almost never move). Absent means "same as
/// last time", so fill them back in from the last snapshot that carried them.
function mergeOmittedQueues(s) {
  for (const field of ["manualQueue", "contextQueue", "likedVideoIds"]) {
    if (s[field] == null) {
      s[field] = state.lastQueues[field] || [];
    } else {
      state.lastQueues[field] = s[field];
    }
  }
}

async function refreshState() {
  const s = await api("/api/state");
  renderNowPlaying(s);
}

// ---------- transport ----------

document.getElementById("np-toggle").onclick = () => post("/api/toggle").then(refreshState);
document.getElementById("np-next").onclick = () => post("/api/next").then(refreshState);
document.getElementById("np-prev").onclick = () => post("/api/previous").then(refreshState);
document.getElementById("np-shuffle").onclick = () => post("/api/shuffle").then(refreshState);
document.getElementById("np-like").onclick = async () => {
  if (!state.current) return;
  await post("/api/library/liked/toggle", { track: state.current });
  refreshState();
};

const seekEl = document.getElementById("np-seek");
seekEl.addEventListener("pointerdown", () => (seekEl.dragging = true));
// Without these, starting a drag and then releasing outside the slider (or letting the
// window lose focus mid-drag) left `dragging` stuck true forever — and while it's true
// the progress bar stops accepting updates from the phone, so the whole seek bar and
// elapsed time silently froze until the page was reloaded.
["pointercancel", "blur"].forEach((ev) => seekEl.addEventListener(ev, () => (seekEl.dragging = false)));
// Live feedback while scrubbing, instead of the elapsed time sitting still until release.
seekEl.addEventListener("input", () => {
  document.getElementById("np-elapsed").textContent = fmtTime(Number(seekEl.value));
});
seekEl.addEventListener("change", async () => {
  const seconds = Number(seekEl.value);
  if (state.isCastTab && audioEl.src) audioEl.currentTime = seconds;
  await post("/api/seek", { seconds });
  seekEl.dragging = false;
  refreshState();
});

// ---------- keyboard control ----------

/// A remote you drive from across the room is far more useful from the keyboard than by
/// aiming at small buttons. Typing in the search box (or any other field) is left alone.
document.addEventListener("keydown", (e) => {
  const el = document.activeElement;
  const typing = el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.isContentEditable);
  if (typing) {
    if (e.key === "Escape") el.blur();
    return;
  }
  if (e.metaKey || e.ctrlKey || e.altKey) return;

  const seekBy = (delta) => {
    const target = Math.max(0, Math.min(Number(seekEl.max) || 0, (state.last ? state.last.progress : 0) + delta));
    if (state.isCastTab && audioEl.src) audioEl.currentTime = target;
    post("/api/seek", { seconds: target }).then(refreshState);
  };

  switch (e.key) {
    case " ":
      e.preventDefault(); // otherwise the page scrolls
      post("/api/toggle").then(refreshState);
      break;
    case "ArrowRight": e.preventDefault(); seekBy(10); break;
    case "ArrowLeft": e.preventDefault(); seekBy(-10); break;
    case "n": case "N": post("/api/next").then(refreshState); break;
    case "p": case "P": post("/api/previous").then(refreshState); break;
    case "s": case "S": post("/api/shuffle").then(refreshState); break;
    case "l": case "L":
      if (state.current) post("/api/library/liked/toggle", { track: state.current }).then(refreshState);
      break;
    case "/":
      e.preventDefault();
      showView("search");
      document.getElementById("global-search").focus();
      break;
  }
});

// ---------- home ----------

function gridTrackCard(track, tracks, contextTitle) {
  const card = document.createElement("div");
  card.className = "grid-card";
  card.innerHTML = `
    <div class="g-art-wrap">
      <img src="${art(track.thumbnailUrl, 170)}" alt="" loading="lazy">
      <button class="g-queue-btn" title="Add to queue">${ICONS.add}</button>
    </div>
    <div class="g-title">${escapeHtml(track.title)}</div>
    <div class="g-artist">${escapeHtml(track.artist)}</div>
  `;
  card.querySelector(".g-queue-btn").onclick = (e) => {
    e.stopPropagation();
    post("/api/queue/add", { track });
  };
  card.onclick = () => post("/api/play", { track, context: tracks, contextTitle }).then(refreshState);
  return card;
}

async function loadHomeRadios() {
  const stations = await api("/api/library/radios");
  const container = document.getElementById("home-radios");
  container.innerHTML = "";
  stations.forEach((station) => {
    const chip = document.createElement("div");
    chip.className = "radio-chip";
    chip.innerHTML = `
      <img src="${art(station.seedTrack.thumbnailUrl, 64)}" alt="" loading="lazy">
      <span class="r-title">${escapeHtml(station.seedTrack.title)} Radio</span>
    `;
    chip.onclick = async () => {
      const tracks = await api(`/api/radio?videoId=${encodeURIComponent(station.seedTrack.videoId)}`);
      openRadioDetail(station.seedTrack, tracks);
    };
    container.appendChild(chip);
  });
}

async function loadHomeRecommendations() {
  const container = document.getElementById("home-recommendations");
  container.innerHTML = "";
  const sections = await api("/api/home");
  if (!sections.length) {
    const empty = document.createElement("div");
    empty.className = "empty-hint";
    empty.textContent = "Play a few songs and your recommendations will show up here.";
    container.appendChild(empty);
    return;
  }
  sections.forEach((section) => {
    const shelf = document.createElement("div");
    shelf.className = "shelf";
    const title = document.createElement("div");
    title.className = "shelf-title";
    title.textContent = section.title;
    const scroll = document.createElement("div");
    scroll.className = "shelf-scroll";
    section.tracks.forEach((t) => scroll.appendChild(gridTrackCard(t, section.tracks, section.title)));
    shelf.appendChild(title);
    shelf.appendChild(scroll);
    container.appendChild(shelf);
  });
}

function loadHome() {
  loadHomeRadios();
  loadHomeRecommendations();
}

// ---------- search ----------

let searchTimer = null;
function runSearch(q) {
  clearTimeout(searchTimer);
  if (!q.trim()) {
    renderList(document.getElementById("search-list"), []);
    return;
  }
  searchTimer = setTimeout(async () => {
    const tracks = await api(`/api/search?q=${encodeURIComponent(q)}`);
    renderList(document.getElementById("search-list"), tracks, {
      scope: `search:${q}`,
      onPlay: (t) => post("/api/play", { track: t, context: tracks, contextTitle: "Search" }).then(refreshState),
    });
  }, 350);
}

document.getElementById("global-search").addEventListener("input", (e) => {
  const q = e.target.value;
  showView("search");
  runSearch(q);
});

document.getElementById("global-search").addEventListener("focus", () => showView("search"));

// ---------- library (sidebar list: playlists + radio stations) ----------

async function loadLibraryList() {
  const [playlists, stations] = await Promise.all([api("/api/library/playlists"), api("/api/library/radios")]);
  const container = document.getElementById("library-list");
  container.innerHTML = "";

  if (stations.length) {
    const label = document.createElement("div");
    label.className = "library-section-label";
    label.textContent = "Radio";
    container.appendChild(label);
    stations.forEach((station) => {
      const row = document.createElement("button");
      row.className = "library-row";
      row.innerHTML = `
        <span class="lib-icon"><img src="${art(station.seedTrack.thumbnailUrl, 32)}" alt="" loading="lazy"></span>
        <span class="track-title-sm">${escapeHtml(station.seedTrack.title)} Radio</span>
      `;
      row.onclick = async () => {
        document.querySelectorAll(".lib-shortcut, .library-row, .nav-item").forEach((b) => b.classList.remove("active"));
        row.classList.add("active");
        const tracks = await api(`/api/radio?videoId=${encodeURIComponent(station.seedTrack.videoId)}`);
        openRadioDetail(station.seedTrack, tracks);
      };
      container.appendChild(row);
    });
  }

  const label = document.createElement("div");
  label.className = "library-section-label";
  label.textContent = "Playlists";
  container.appendChild(label);

  if (!playlists.length) {
    const empty = document.createElement("div");
    empty.className = "empty-hint";
    empty.textContent = "Tap Create to add one.";
    container.appendChild(empty);
  } else {
    playlists.forEach((p) => {
      const row = document.createElement("button");
      row.className = "library-row";
      const cover = p.tracks[0] ? art(p.tracks[0].thumbnailUrl, 32) : null;
      row.innerHTML = `
        <span class="lib-icon">${cover ? `<img src="${cover}" alt="" loading="lazy">` : ICONS.note}</span>
        <span class="track-title-sm">${escapeHtml(p.name)}<span class="row-sub">${p.tracks.length} songs</span></span>
      `;
      row.onclick = () => {
        document.querySelectorAll(".lib-shortcut, .library-row, .nav-item").forEach((b) => b.classList.remove("active"));
        row.classList.add("active");
        openPlaylistDetail(p);
      };
      container.appendChild(row);
    });
  }
}

document.getElementById("new-playlist-btn").onclick = async () => {
  const input = document.getElementById("new-playlist-name");
  const name = input.value.trim();
  if (!name) return;
  await post("/api/library/playlists/create", { name });
  input.value = "";
  loadLibraryList();
};

// ---------- live sync ----------

function connectWebSocket() {
  const ws = new WebSocket(`ws://${location.host}/ws`);
  let heartbeat = null;
  ws.onopen = () => {
    // Lets the server tell this connection apart from one that silently died (closed
    // laptop lid, WiFi drop) without a clean close ever reaching it — see
    // LocalControlServer's socketLastSeen/pruneStaleSockets. Every frame carries this
    // tab's id so the phone knows whether the socket belonging to the *casting* tab in
    // particular is still alive, which is what the fall-back-to-iPhone decision hangs on.
    // Sent immediately on connect too, not just on the 15s heartbeat, so a reconnect is
    // re-attributed well inside that grace period.
    const hello = () => {
      if (ws.readyState === WebSocket.OPEN) ws.send(`hello:${CLIENT_ID}`);
    };
    hello();
    heartbeat = setInterval(hello, 15000);
    // Back in touch: if this tab kept playing without the phone, square that up now.
    reconcileAfterDisconnection();
  };
  ws.onmessage = (event) => {
    try {
      const msg = JSON.parse(event.data);
      if (msg.type === "radio") {
        // A radio's mix changed (refreshed from the phone or another browser tab) —
        // if that's the one currently open here, update it live instead of going stale.
        if (detail.kind === "radio" && detail.seedTrack && detail.seedTrack.videoId === msg.videoId) {
          openRadioDetail(detail.seedTrack, msg.tracks);
        }
      } else if (msg.type === "state") {
        renderNowPlaying(msg.state);
      } else if (msg.type === "command" && state.isCastTab) {
        // Toggle/seek issued from the phone (lock screen, app UI) while this tab is
        // casting — for seek, apply the exact position; for toggle, just resync from
        // the definitive state rather than blindly flipping, so this can't double-apply
        // if the same command also arrives via the tab's own POST -> refreshState path.
        if (msg.action === "seek" && typeof msg.seconds === "number" && audioEl.src) {
          audioEl.currentTime = msg.seconds;
        } else if (msg.action === "toggle") {
          refreshState();
        }
      }
    } catch (e) {
      /* ignore malformed frame */
    }
  };
  ws.onclose = () => {
    if (heartbeat) clearInterval(heartbeat);
    setTimeout(connectWebSocket, 2000);
  };
  ws.onerror = () => ws.close();
}

// ---------- init ----------

loadHome();
loadLibraryList();
refreshState();
connectWebSocket();
setInterval(refreshState, 5000); // fallback in case the socket drops silently
