const state = {
  current: null,
  likedIds: new Set(),
};

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
  img.src = track.thumbnailUrl || "";
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

function renderList(container, tracks, opts) {
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
    imageURL: seedTrack.thumbnailUrl,
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
    imageURL: daylist.tracks[0] ? daylist.tracks[0].thumbnailUrl : null,
    kind: "daylist",
    showRefresh: true,
  });
}

async function openPlaylistDetail(playlist) {
  openDetail(playlist.tracks, {
    title: playlist.name,
    subtitle: `${playlist.tracks.length} songs`,
    badge: "Playlist",
    imageURL: playlist.tracks[0] ? playlist.tracks[0].thumbnailUrl : null,
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

// ---------- now playing ----------

function renderNowPlaying(s) {
  state.current = s.currentTrack;
  document.getElementById("np-art").src = s.currentTrack ? s.currentTrack.thumbnailUrl || "" : "";
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
seekEl.addEventListener("mousedown", () => (seekEl.dragging = true));
seekEl.addEventListener("touchstart", () => (seekEl.dragging = true));
seekEl.addEventListener("change", async () => {
  await post("/api/seek", { seconds: Number(seekEl.value) });
  seekEl.dragging = false;
  refreshState();
});

// ---------- home ----------

function gridTrackCard(track, tracks, contextTitle) {
  const card = document.createElement("div");
  card.className = "grid-card";
  card.innerHTML = `
    <div class="g-art-wrap">
      <img src="${track.thumbnailUrl || ""}" alt="">
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
      <img src="${station.seedTrack.thumbnailUrl || ""}" alt="">
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
        <span class="lib-icon"><img src="${station.seedTrack.thumbnailUrl || ""}" alt=""></span>
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
      const art = p.tracks[0] ? p.tracks[0].thumbnailUrl : null;
      row.innerHTML = `
        <span class="lib-icon">${art ? `<img src="${art}" alt="">` : ICONS.note}</span>
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
    // LocalControlServer's socketLastSeen/pruneStaleSockets.
    heartbeat = setInterval(() => {
      if (ws.readyState === WebSocket.OPEN) ws.send("ping");
    }, 15000);
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
