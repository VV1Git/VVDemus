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
  // The highest epochs actually applied to the UI, so an out-of-order snapshot arriving
  // from the slower of the two transports can be dropped rather than rewinding the page
  // to a state the phone has already moved past. See isStaleSnapshot.
  appliedEpoch: null,
  appliedTrackLoadEpoch: null,
  // Which run of the phone app the epochs above belong to; they mean nothing across a
  // restart. See isStaleSnapshot.
  serverInstanceId: null,
  lastAppliedAt: 0,
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
  // Last library shape seen from the phone; a change reloads the sidebar.
  librarySignature: null,
  // Until this moment, play/pause events from the element are our own doing rather than
  // the operating system's.
  ignoreEchoUntil: 0,
  mediaSessionTrack: null,
  // A play/pause relayed to the phone that we haven't seen come back yet.
  pendingPlayIntent: null,
  // Whether the phone is currently answering at all, so the page can say so instead of
  // freezing on a stale snapshot while every click quietly fails.
  phoneUnreachable: false,
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

// How long to wait for the phone before treating it as unreachable.
//
// Every request needs one. Without a timeout, a phone that is asleep or off the network
// doesn't refuse the connection — the TCP handshake just retransmits, so `fetch` stays
// pending for thirty to ninety seconds before rejecting. That matters most at the end of
// a track: the whole prefetched-next-track mechanism lives in the `catch` of
// `/api/next`, so instead of continuing seamlessly the music went silent for a minute
// first — the exact failure the prefetch was built to prevent.
const REQUEST_TIMEOUT_MS = 2000;
/// For requests where the phone itself has to hit the network before it can answer —
/// search, Home, a radio fetch, a daylist rebuild. These routinely take several seconds,
/// and holding them to the transport deadline made a perfectly healthy phone look broken:
/// empty search results, a permanently blank Home, and Refresh buttons that did nothing.
const CONTENT_TIMEOUT_MS = 20000;

async function api(path, options = {}, timeoutMs = REQUEST_TIMEOUT_MS) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(path, { ...options, signal: controller.signal });
    if (!res.ok) throw new Error(`${path} -> ${res.status}`);
    const contentType = res.headers.get("content-type") || "";
    return contentType.includes("application/json") ? res.json() : res.text();
  } finally {
    clearTimeout(timer);
  }
}

function post(path, body, timeoutMs) {
  return api(
    path,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body ?? {}),
    },
    timeoutMs
  );
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

// ---------- right-click track menu ----------

/// The web counterpart of the app's long-press menu. Everything here already existed as an
/// endpoint; the remote just had no way to reach most of it, so adding a song to a playlist
/// or opening its radio meant picking up the phone.
const contextMenuEl = document.getElementById("context-menu");

const MENU_ICONS = {
  playNext: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M3 6h11v2H3zm0 5h11v2H3zm0 5h7v2H3zm13-8 6 4-6 4z"/></svg>',
  queue: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M3 6h13v2H3zm0 5h13v2H3zm0 5h9v2H3zm15-6h2v3h3v2h-3v3h-2v-3h-3v-2h3z"/></svg>',
  radio: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 10.5a1.5 1.5 0 1 1 0 3 1.5 1.5 0 0 1 0-3zM7.8 6.3 6.4 4.9a10 10 0 0 0 0 14.2l1.4-1.4a8 8 0 0 1 0-11.4zm8.4 0a8 8 0 0 1 0 11.4l1.4 1.4a10 10 0 0 0 0-14.2zM9.9 8.4 8.5 7a7 7 0 0 0 0 10l1.4-1.4a5 5 0 0 1 0-7.2zm4.2 0a5 5 0 0 1 0 7.2l1.4 1.4a7 7 0 0 0 0-10z"/></svg>',
  playlist: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M3 5h12v2H3zm0 4h12v2H3zm0 4h8v2H3zm14-4h2v4h4v2h-4v4h-2v-4h-4v-2h4z"/></svg>',
  download: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M11 3h2v9l3.5-3.5 1.4 1.4L12 16 6.1 9.9l1.4-1.4L11 12zM5 18h14v2H5z"/></svg>',
  trash: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M8 3h8l1 2h4v2H3V5h4zM5 8h14l-1 12H6z"/></svg>',
  back: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M15.4 7.4 14 6l-6 6 6 6 1.4-1.4L10.8 12z"/></svg>',
};

/// Downloaded state isn't part of the periodic state broadcast (it changes rarely and the
/// list can be long), so it's fetched when a menu opens and cached briefly.
let downloadsCache = { ids: new Set(), at: 0 };

async function downloadedIds() {
  if (Date.now() - downloadsCache.at < 15000) return downloadsCache.ids;
  try {
    const tracks = await api("/api/library/downloads");
    downloadsCache = { ids: new Set(tracks.map((t) => t.videoId)), at: Date.now() };
  } catch (e) {
    /* keep whatever we had */
  }
  return downloadsCache.ids;
}

function closeContextMenu() {
  contextMenuEl.classList.remove("open");
  contextMenuEl.setAttribute("aria-hidden", "true");
  contextMenuEl.innerHTML = "";
}

document.addEventListener("click", closeContextMenu);
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") closeContextMenu();
});
window.addEventListener("blur", closeContextMenu);
// Capture phase: the menu is fixed-positioned, so it would otherwise hang in place while
// the list behind it scrolls away.
document.addEventListener("scroll", closeContextMenu, true);
window.addEventListener("resize", closeContextMenu);

function menuButton(label, icon, onClick, { liked } = {}) {
  const button = document.createElement("button");
  button.type = "button";
  button.setAttribute("role", "menuitem");
  button.innerHTML = `${icon}<span></span>`;
  button.querySelector("span").textContent = label;
  if (liked) button.classList.add("liked");
  button.onclick = async (e) => {
    e.stopPropagation();
    closeContextMenu();
    await onClick();
  };
  return button;
}

function menuSeparator() {
  const el = document.createElement("div");
  el.className = "context-menu-separator";
  return el;
}

/// Positions the menu at the cursor, pulled back inside the viewport when it would
/// otherwise overhang — right-clicking a row near the bottom of the window is the norm,
/// not the exception.
function placeContextMenu(x, y) {
  contextMenuEl.classList.add("open");
  contextMenuEl.setAttribute("aria-hidden", "false");
  contextMenuEl.style.left = "0px";
  contextMenuEl.style.top = "0px";
  const rect = contextMenuEl.getBoundingClientRect();
  const left = Math.max(8, Math.min(x, window.innerWidth - rect.width - 8));
  const top = Math.max(8, Math.min(y, window.innerHeight - rect.height - 8));
  contextMenuEl.style.left = `${left}px`;
  contextMenuEl.style.top = `${top}px`;
}

async function openTrackMenu(event, track, { onRemove, removeLabel } = {}) {
  event.preventDefault();
  event.stopPropagation();
  contextMenuEl.innerHTML = "";

  const title = document.createElement("div");
  title.className = "context-menu-title";
  title.textContent = `${track.title} — ${track.artist}`;
  contextMenuEl.appendChild(title);

  contextMenuEl.appendChild(menuButton("Play Next", MENU_ICONS.playNext, () =>
    post("/api/queue/play-next", { track }).then(refreshState)));
  contextMenuEl.appendChild(menuButton("Add to Queue", MENU_ICONS.queue, () =>
    post("/api/queue/add", { track }).then(refreshState)));

  contextMenuEl.appendChild(menuSeparator());

  contextMenuEl.appendChild(menuButton("Go to Radio", MENU_ICONS.radio, async () => {
    const tracks = await api(`/api/radio?videoId=${encodeURIComponent(track.videoId)}`, {}, CONTENT_TIMEOUT_MS);
    openRadioDetail(track, tracks);
  }));

  const isLiked = state.likedIds.has(track.videoId);
  contextMenuEl.appendChild(menuButton(
    isLiked ? "Remove from Liked Songs" : "Save to Liked Songs",
    isLiked ? ICONS.heartFilled : ICONS.heartOutline,
    () => post("/api/library/liked/toggle", { track }).then(refreshState),
    { liked: isLiked }
  ));

  // Rendered immediately with a placeholder rather than awaited, so the menu appears
  // under the cursor at once instead of after a round trip.
  const playlistButton = menuButton("Add to Playlist", MENU_ICONS.playlist, () => {});
  playlistButton.onclick = (e) => {
    e.stopPropagation();
    showPlaylistPicker(track);
  };
  contextMenuEl.appendChild(playlistButton);

  const downloadSlot = document.createElement("div");
  contextMenuEl.appendChild(downloadSlot);

  if (onRemove) {
    contextMenuEl.appendChild(menuSeparator());
    contextMenuEl.appendChild(menuButton(removeLabel || "Remove from Queue", MENU_ICONS.trash, () => onRemove(track)));
  }

  placeContextMenu(event.clientX, event.clientY);

  const downloaded = await downloadedIds();
  if (!contextMenuEl.classList.contains("open")) return; // closed while we waited
  downloadSlot.appendChild(
    downloaded.has(track.videoId)
      ? menuButton("Remove Download", MENU_ICONS.trash, async () => {
          await post("/api/library/download/remove", { track });
          downloadsCache.at = 0;
        })
      : menuButton("Download", MENU_ICONS.download, async () => {
          await post("/api/library/download", { track });
          downloadsCache.at = 0;
        })
  );
  placeContextMenu(event.clientX, event.clientY); // re-clamp now that it's taller
}

/// Second level of the menu, shown in place rather than as a flyout — a nested submenu
/// that has to track the cursor is far more code and far easier to get wrong.
async function showPlaylistPicker(track) {
  contextMenuEl.innerHTML = "";

  const header = document.createElement("div");
  header.className = "context-menu-header";
  header.textContent = "Add to playlist";
  contextMenuEl.appendChild(header);

  const back = menuButton("Back", MENU_ICONS.back, () => {});
  back.onclick = (e) => {
    e.stopPropagation();
    openTrackMenu(
      { preventDefault() {}, stopPropagation() {}, clientX: lastMenuPosition.x, clientY: lastMenuPosition.y },
      track
    );
  };
  contextMenuEl.appendChild(back);
  contextMenuEl.appendChild(menuSeparator());

  const listSlot = document.createElement("div");
  contextMenuEl.appendChild(listSlot);

  const newRow = document.createElement("div");
  const newInput = document.createElement("input");
  newInput.type = "text";
  newInput.placeholder = "New playlist name…";
  newInput.onclick = (e) => e.stopPropagation();
  newInput.onkeydown = async (e) => {
    e.stopPropagation();
    if (e.key !== "Enter") return;
    const name = newInput.value.trim();
    if (!name) return;
    closeContextMenu();
    await post("/api/library/playlists/create", { name });
    // create doesn't hand back an id, so find the playlist it just made by name.
    const playlists = await api("/api/library/playlists");
    const created = playlists.find((p) => p.name === name);
    if (created) await post(`/api/library/playlists/${created.id}/add`, { track });
    loadLibraryList();
  };
  newRow.appendChild(newInput);
  contextMenuEl.appendChild(newRow);

  placeContextMenu(lastMenuPosition.x, lastMenuPosition.y);

  let playlists = [];
  try {
    playlists = await api("/api/library/playlists");
  } catch (e) {
    /* offline — the new-playlist field still works once the phone is back */
  }
  if (!contextMenuEl.classList.contains("open")) return;
  playlists.forEach((playlist) => {
    listSlot.appendChild(
      menuButton(playlist.name, MENU_ICONS.playlist, async () => {
        await post(`/api/library/playlists/${playlist.id}/add`, { track });
        loadLibraryList();
      })
    );
  });
  placeContextMenu(lastMenuPosition.x, lastMenuPosition.y);
  newInput.focus();
}

/// Remembered so the picker (and the way back out of it) can reopen in the same spot.
let lastMenuPosition = { x: 0, y: 0 };

function attachTrackMenu(element, track, opts) {
  element.addEventListener("contextmenu", (e) => {
    lastMenuPosition = { x: e.clientX, y: e.clientY };
    openTrackMenu(e, track, opts);
  });
  // Touch equivalent, for driving the remote from a tablet.
  let longPress = null;
  element.addEventListener("touchstart", (e) => {
    const touch = e.touches[0];
    longPress = setTimeout(() => {
      lastMenuPosition = { x: touch.clientX, y: touch.clientY };
      openTrackMenu({ preventDefault() {}, stopPropagation() {}, clientX: touch.clientX, clientY: touch.clientY }, track, opts);
    }, 500);
  }, { passive: true });
  ["touchend", "touchmove", "touchcancel"].forEach((ev) =>
    element.addEventListener(ev, () => clearTimeout(longPress), { passive: true })
  );
}

// ---------- track row rendering ----------

function trackRow(track, { onPlay, showRemove, onRemove } = {}) {
  const row = document.createElement("div");
  row.className = "track-row" + (state.current && state.current.videoId === track.videoId ? " active" : "");

  const artwork = document.createElement("div");
  artwork.className = "track-art";
  const img = document.createElement("img");
  img.src = art(track.thumbnailUrl, 44); // .track-row img is 44px
  artwork.appendChild(img);
  // Animated bars over the artwork of whatever is playing — a green title alone was easy
  // to miss, especially in a long radio where several rows look alike.
  const bars = document.createElement("span");
  bars.className = "playing-bars";
  bars.innerHTML = "<i></i><i></i><i></i>";
  artwork.appendChild(bars);
  row.appendChild(artwork);

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
  attachTrackMenu(row, track, showRemove ? { onRemove, removeLabel: "Remove from Queue" } : {});
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

  // Kept so the open list can be re-rendered when the playing track changes — otherwise
  // the highlight is frozen at whatever was playing when the view was opened, which is
  // why starting a radio never showed which song was playing.
  detail.rerender = () =>
    renderList(document.getElementById("detail-list"), tracks, {
      scope: `${kind || "detail"}:${title}`,
      onPlay: (t) =>
        post("/api/play", { track: t, context: tracks, contextTitle: title, contextSeed: detail.seedTrack }).then(refreshState),
    });
  detail.rerender();
  showView("detail");
}

document.getElementById("detail-play").onclick = () => {
  if (!detail.tracks.length) return;
  post("/api/play", {
    track: detail.tracks[0],
    context: detail.tracks,
    contextTitle: detail.title,
    contextSeed: detail.seedTrack,
  }).then(refreshState);
};

document.getElementById("detail-shuffle").onclick = () => {
  if (!detail.tracks.length) return;
  const shuffled = [...detail.tracks].sort(() => Math.random() - 0.5);
  post("/api/play", {
    track: shuffled[0],
    context: shuffled,
    contextTitle: detail.title,
    contextSeed: detail.seedTrack,
  }).then(refreshState);
};

document.getElementById("detail-refresh").onclick = async () => {
  if (detail.kind === "radio" && detail.seedTrack) {
    const tracks = await post("/api/radio/refresh", { videoId: detail.seedTrack.videoId }, CONTENT_TIMEOUT_MS);
    openRadioDetail(detail.seedTrack, tracks);
  } else if (detail.kind === "daylist") {
    await post("/api/library/daylist/refresh", {}, CONTENT_TIMEOUT_MS);
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
    // Deliberately a tight timeout: this is the one request where waiting is worse than
    // failing. If the phone can't answer inside a second and a half, the prefetched next
    // track is right here and playing it immediately is strictly better than silence.
    // Names the track that ended: if the phone already moved on (the user pressed next a
    // moment ago), this must be a no-op rather than skipping another song.
    await post("/api/next", { videoId: state.loadedVideoId }, 1500);
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
  suppressPlaybackEcho();
  audioEl.pause();
  audioEl.removeAttribute("src");
  audioEl.load();
  state.loadedVideoId = null;
  state.loadedTrackEpoch = null;
}

function unlockAudioElementForGesture() {
  suppressPlaybackEcho();
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
  suppressPlaybackEcho();
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

/// Puts the current track in the browser tab, so the song is readable from the tab strip
/// with the remote in the background — which is where it spends most of its time.
/// Rewritten only when it actually changes: this runs on every state broadcast, and
/// assigning document.title once a second makes the tab flicker in some browsers.
function renderDocumentTitle(s) {
  const track = s && s.currentTrack;
  const next = !track
    ? "Spotify"
    : s.isPlaying
      ? `${track.title} • ${track.artist}`
      : `${track.title} • ${track.artist} — paused`;
  if (document.title !== next) document.title = next;
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
function syncCastAudio(s, shouldPlay) {
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
  // A null `loadedTrackEpoch` means *this tab* chose the track (it advanced on its own
  // while the phone was away), so there is no phone load generation to compare against.
  // Comparing anyway guaranteed a spurious reload: the phone deliberately doesn't bump
  // `trackLoadEpoch` when it adopts what we're playing, so the moment the adopt succeeded
  // the very next snapshot re-loaded and re-buffered a track that was playing perfectly —
  // an audible gap exactly when the phone came back. The videoId check below still
  // catches a genuine track change.
  const phoneRestartedTrack =
    state.loadedTrackEpoch !== null && state.loadedTrackEpoch !== s.trackLoadEpoch;
  if (state.loadedVideoId !== videoId || phoneRestartedTrack) {
    // The phone resolves streamUrl asynchronously after a device switch (or a new track
    // starting), so a snapshot can name the new track while streamUrl is still empty —
    // or, worse, still holds the *previous* track's URL. `streamVideoId` says which track
    // the URL was resolved for; anything else means "not ready yet", and loading it would
    // leave this computer playing one track behind the phone with nothing to correct it.
    if (!s.streamUrl || s.streamVideoId !== videoId) return;
    // Don't hammer a URL that just failed to load; let the next track (or a re-resolve
    // after a device switch) get a fresh one instead of retrying every broadcast tick.
    if (s.streamUrl === state.failedSrc && Date.now() - state.failedAt < 5000) return;
    suppressPlaybackEcho();
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
  // Passed in: `desiredPlayState` mutates the pending intent and can fire a retry POST, so
  // it must be evaluated exactly once per snapshot.
  // `!audioEl.ended` matters: at the end of a track the element is both paused *and*
  // ended, and calling play() on an ended element seeks it back to zero and starts the
  // song again. Between the `ended` event and the phone answering /api/next, every
  // broadcast still named the finished track — so each track transition began with a
  // burst of the outgoing song's opening seconds.
  if (shouldPlay && audioEl.paused && !audioEl.ended) playCastAudio();
  if (!shouldPlay && !audioEl.paused) {
    suppressPlaybackEcho();
    audioEl.pause();
  }
}

/// Changing `src`, or starting/stopping playback ourselves, makes the element fire the
/// same play/pause events the operating system's controls do. This marks a short window
/// in which those events are known to be our own doing.
function suppressPlaybackEcho() {
  state.ignoreEchoUntil = Date.now() + 1200;
}

/// macOS Control Center, the media keys and the Touch Bar all act on the <audio> element
/// directly — the phone never hears about it. So the next state broadcast, still saying
/// "playing", would find the element paused and start it again: pressing pause stopped
/// the music for a moment and then it carried on.
///
/// Instead, a play/pause that disagrees with what the phone believes is treated as a
/// genuine instruction and sent on, so the phone becomes the one source of truth again.
function onPlaybackEcho(nowPlaying) {
  if (!state.isCastTab || audioEl.ended) return;
  // The silent clip played to unlock autoplay is our own doing, not the user's — reading
  // its play event as intent started a paused track playing on handover.
  if (audioEl.currentSrc === SILENT_UNLOCK_SRC) return;
  if (Date.now() < (state.ignoreEchoUntil || 0)) return;
  // Nothing loaded yet — the element reports paused without anyone having asked for it.
  if (!audioEl.getAttribute("src")) return;
  // Only skip when we positively know the phone already agrees. With no state yet,
  // swallowing the instruction would leave the audio running after the OS paused it.
  if (state.last && state.last.isPlaying === nowPlaying) return;

  // Hold on to what was asked for until the phone reflects it. Telling the phone isn't
  // instant, and a state broadcast arriving in the meantime still says "playing" — which
  // would restart the audio a moment after it was paused. That half-second of sound is
  // enough to stop AirPods handing over to the Mac, since the handover waits for the
  // current device to actually go quiet.
  state.pendingPlayIntent = { playing: nowPlaying, at: Date.now() };
  post("/api/toggle").then(refreshState).catch(() => {});
}

/// What playback *should* be doing: normally whatever the phone says, but an instruction
/// we've just relayed and are still waiting to see reflected wins until it lands.
function desiredPlayState(s) {
  const pending = state.pendingPlayIntent;
  if (!pending) return s.isPlaying;
  if (s.isPlaying === pending.playing) {
    state.pendingPlayIntent = null;
    return s.isPlaying;
  }
  const age = Date.now() - pending.at;
  if (age > 5000) {
    // Checked first: a stale intent that already had its retry must expire rather than
    // fire another toggle. Reaching the retry branch below after five seconds meant a tab
    // that re-acquired casting could pause music the user had just started.
    state.pendingPlayIntent = null;
    return s.isPlaying;
  }
  if (!pending.retried) {
    // The request can simply have been lost. Ask again rather than letting audio the OS
    // stopped spring back to life — this failing towards "starts playing on its own" is
    // exactly what breaks an AirPods handover.
    pending.retried = true;
    pending.at = Date.now();
    if (age > 2500) {
      pending.retried = true;
      pending.at = Date.now();
      post("/api/toggle").then(refreshState).catch(() => {});
    }
  }
  return pending.playing;
}

audioEl.addEventListener("pause", () => onPlaybackEcho(false));
audioEl.addEventListener("play", () => onPlaybackEcho(true));

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
    clientId: CLIENT_ID,
    progress: audioEl.currentTime,
    duration: isFinite(audioEl.duration) ? audioEl.duration : 0,
    isPlaying: !audioEl.paused,
  }).catch(() => {});
});

// ---------- macOS / OS media controls ----------

/// Registers this tab with the operating system's media controls, so Control Center, the
/// media keys, the Touch Bar and the lock screen can drive playback — and show what's on.
///
/// Without this the OS could only reach the raw <audio> element: pause worked for a
/// moment before the next state broadcast undid it, and skip/rewind did nothing at all
/// because there is nothing in the element itself to skip to. Each control is mapped to
/// the same endpoint the on-screen buttons use, so the phone stays the source of truth.
function setupMediaSession() {
  if (!("mediaSession" in navigator)) return;
  const handlers = {
    play: () => post("/api/toggle").then(refreshState),
    pause: () => post("/api/toggle").then(refreshState),
    nexttrack: () => post("/api/next").then(refreshState),
    previoustrack: () => post("/api/previous").then(refreshState),
    seekto: (details) => {
      if (typeof details.seekTime !== "number") return;
      suppressPlaybackEcho();
      audioEl.currentTime = details.seekTime;
      post("/api/seek", { seconds: details.seekTime }).then(refreshState);
    },
    seekforward: (d) => seekRelative(d.seekOffset || 10),
    seekbackward: (d) => seekRelative(-(d.seekOffset || 10)),
    stop: () => post("/api/toggle").then(refreshState),
  };
  for (const [action, handler] of Object.entries(handlers)) {
    try {
      navigator.mediaSession.setActionHandler(action, handler);
    } catch (e) {
      /* not every browser supports every action */
    }
  }
}

function seekRelative(delta) {
  const target = Math.max(0, (state.last ? state.last.progress : 0) + delta);
  suppressPlaybackEcho();
  if (audioEl.src) audioEl.currentTime = target;
  post("/api/seek", { seconds: target }).then(refreshState);
}

/// Feeds the OS the track details it displays next to those controls. Only rebuilt when
/// the track changes — MediaMetadata triggers an artwork fetch, so doing this on every
/// state broadcast would re-download the artwork once a second.
function renderMediaSession(s, playing) {
  if (!("mediaSession" in navigator)) return;
  const track = state.isCastTab ? s.currentTrack : null;
  if (!track) {
    navigator.mediaSession.metadata = null;
    navigator.mediaSession.playbackState = "none";
    state.mediaSessionTrack = null;
    return;
  }
  if (state.mediaSessionTrack !== track.videoId) {
    state.mediaSessionTrack = track.videoId;
    navigator.mediaSession.metadata = new MediaMetadata({
      title: track.title,
      artist: track.artist,
      album: track.album || "",
      artwork: track.thumbnailUrl
        ? [{ src: art(track.thumbnailUrl, 256), sizes: "256x256", type: "image/jpeg" }]
        : [],
    });
  }
  // The resolved state, not the raw snapshot: telling the OS "playing" while the element
  // is deliberately paused makes the next media-key press send `pause` again, which maps
  // to a toggle and starts the music back up.
  navigator.mediaSession.playbackState = playing ? "playing" : "paused";
  // Drives the scrubber in Control Center.
  if (navigator.mediaSession.setPositionState && isFinite(s.duration) && s.duration > 0) {
    try {
      navigator.mediaSession.setPositionState({
        duration: s.duration,
        position: Math.min(Math.max(s.progress, 0), s.duration),
        playbackRate: 1,
      });
    } catch (e) {
      /* position outside duration during a track change */
    }
  }
}

// ---------- now playing ----------

/// Whether a snapshot is newer than the newest one already applied.
///
/// State arrives over two unordered transports: the 1 Hz WebSocket broadcast and HTTP
/// `GET /api/state` (a 5 s poll, plus a refresh chased after every command). Nothing
/// sequenced them, so a poll issued *before* the user pressed next could arrive *after*
/// the phone had already broadcast the new track — and being applied unconditionally, it
/// reloaded the previous track's stream and played it. It also dragged `state.epoch`
/// backwards, so every progress report for the next second was discarded by the phone as
/// stale. The phone already stamps each snapshot with `playbackEpoch`; this just refuses
/// to go back in time. `trackLoadEpoch` is checked too, since it moves independently when
/// a track restarts.
function isStaleSnapshot(s) {
  if (typeof s.playbackEpoch !== "number") return false;
  // The phone's epoch counter restarts at 0 on every launch. Without noticing that, a
  // browser holding a high epoch rejects every snapshot from a relaunched phone *forever*:
  // the socket reconnects and /api/state returns 200, so the page looks perfectly healthy
  // while being completely frozen on its last state — and if it was the casting tab, the
  // music stops on both devices with no way back but a manual reload.
  if (s.serverInstanceId && s.serverInstanceId !== state.serverInstanceId) {
    state.serverInstanceId = s.serverInstanceId;
    state.appliedEpoch = null;
    state.appliedTrackLoadEpoch = null;
    return false;
  }
  // Belt and braces: no correctness guard is worth a permanently dead page. If nothing has
  // been applied for several seconds, take whatever arrives.
  if (state.lastAppliedAt && Date.now() - state.lastAppliedAt > 4000) return false;
  if (state.appliedEpoch === null || state.appliedEpoch === undefined) return false;
  if (s.playbackEpoch > state.appliedEpoch) return false;
  if (s.playbackEpoch < state.appliedEpoch) return true;
  // Same playback epoch: a lower trackLoadEpoch is still a snapshot from before the
  // current track was (re)started.
  return typeof s.trackLoadEpoch === "number" &&
    typeof state.appliedTrackLoadEpoch === "number" &&
    s.trackLoadEpoch < state.appliedTrackLoadEpoch;
}

function renderNowPlaying(s) {
  if (isStaleSnapshot(s)) return;
  state.appliedEpoch = s.playbackEpoch;
  state.appliedTrackLoadEpoch = s.trackLoadEpoch;
  state.lastAppliedAt = Date.now();
  mergeOmittedQueues(s);
  state.upNext = s.nextTrack && s.nextStreamUrl ? { track: s.nextTrack, streamUrl: s.nextStreamUrl } : null;
  state.current = s.currentTrack;
  state.last = s;
  state.epoch = s.playbackEpoch;
  // One evaluation, shared by the audio element and every visual indicator below. They
  // used to disagree: the element obeyed `desiredPlayState` while the icons read raw
  // `s.isPlaying`, so pausing from the Mac's media keys showed a pause glyph over silence
  // and — worse — reset `navigator.mediaSession.playbackState` to "playing", making the
  // user's next media-key press start the music again instead of resuming it.
  const playing = desiredPlayState(s);
  syncCastAudio(s, playing); // sets state.isCastTab, which the label depends on
  renderDeviceLabel();
  renderDocumentTitle(s);
  const npArt = document.getElementById("np-art");
  npArt.src = s.currentTrack ? art(s.currentTrack.thumbnailUrl, 56) : "";
  // The phone resolving a stream can take a second or two; without any sign of it, the
  // remote just looked frozen between pressing play and hearing anything.
  npArt.classList.toggle("loading", !!s.isLoading);
  document.getElementById("np-title").textContent = s.currentTrack ? s.currentTrack.title : "Nothing playing";
  document.getElementById("np-artist").textContent = s.currentTrack ? s.currentTrack.artist : "";
  document.getElementById("np-play-icon").style.display = playing ? "none" : "block";
  document.getElementById("np-pause-icon").style.display = playing ? "block" : "none";
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
  renderMediaSession(s, playing);

  // Freezes the equalizer bars while paused, so the marker still shows where you are.
  document.body.classList.toggle("playback-paused", !playing);

  // renderList no-ops when nothing changed, so this is only work when it matters.
  if (detail.rerender) detail.rerender();

  // A radio started from anywhere — this tab, the phone, or autoplay — shows up in the
  // sidebar as soon as the phone reports its library changed shape.
  if (state.librarySignature !== null && s.librarySignature !== state.librarySignature) {
    loadLibraryList();
  }
  state.librarySignature = s.librarySignature;

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
  try {
    await post("/api/seek", { seconds });
  } finally {
    // In a `finally`: if the POST times out, leaving this true freezes the scrubber and
    // the elapsed time until the page is reloaded, because renderNowPlaying skips seek-bar
    // updates while a drag is in progress.
    seekEl.dragging = false;
    refreshState().catch(() => {});
  }
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
  attachTrackMenu(card, track);
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
      const tracks = await api(`/api/radio?videoId=${encodeURIComponent(station.seedTrack.videoId)}`, {}, CONTENT_TIMEOUT_MS);
      openRadioDetail(station.seedTrack, tracks);
    };
    container.appendChild(chip);
  });
}

async function loadHomeRecommendations() {
  const container = document.getElementById("home-recommendations");
  container.innerHTML = "";
  const sections = await api("/api/home", {}, CONTENT_TIMEOUT_MS);
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

async function loadHome() {
  // Each half is allowed to fail on its own: one failing fetch shouldn't leave the whole
  // Home screen blank, and neither rejection had a handler before.
  await Promise.allSettled([loadHomeRadios(), loadHomeRecommendations()]);
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
    const tracks = await api(`/api/search?q=${encodeURIComponent(q)}`, {}, CONTENT_TIMEOUT_MS);
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
        const tracks = await api(`/api/radio?videoId=${encodeURIComponent(station.seedTrack.videoId)}`, {}, CONTENT_TIMEOUT_MS);
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
    markPhoneUnreachable(false);
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
    markPhoneUnreachable(true);
    // Backed off rather than a flat 2 s: a phone that's asleep, off the network or simply
    // switched off stays unreachable for hours, and hammering it every two seconds for
    // that whole time is pure battery on both ends.
    reconnectDelay = Math.min(reconnectDelay * 2, 30000);
    setTimeout(connectWebSocket, reconnectDelay);
  };
  ws.onerror = () => ws.close();
}

let reconnectDelay = 1000;

/// Shows (or clears) the "can't reach your iPhone" state. Without it the page simply
/// froze on its last snapshot — still captioned "Playing on iPhone" — while every click
/// silently did nothing, which is indistinguishable from the app having hung.
function markPhoneUnreachable(unreachable) {
  if (unreachable === state.phoneUnreachable) return;
  state.phoneUnreachable = unreachable;
  document.body.classList.toggle("phone-unreachable", unreachable);
  if (!unreachable) reconnectDelay = 1000;
}

// ---------- init ----------

setupMediaSession();
loadHome().catch(() => {});
loadLibraryList().catch(() => {});
refreshState().catch(() => {});
connectWebSocket();
// Fallback in case the socket drops silently. The `.catch` is not optional: while the
// phone is unreachable this rejects every five seconds, and an unhandled rejection in a
// timer stops nothing but fills the console and hides real errors.
setInterval(() => {
  refreshState()
    .then(() => markPhoneUnreachable(false))
    .catch(() => markPhoneUnreachable(true));
}, 5000);
