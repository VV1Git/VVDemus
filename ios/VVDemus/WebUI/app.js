const state = {
  current: null,
  likedIds: new Set(),
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

// ---------- track row rendering ----------

function trackRow(track, { onPlay, showRemove, onRemove, showAddToPlaylist } = {}) {
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
  likeBtn.textContent = state.likedIds.has(track.videoId) ? "♥" : "♡";
  if (state.likedIds.has(track.videoId)) likeBtn.classList.add("liked");
  likeBtn.onclick = async (e) => {
    e.stopPropagation();
    await post("/api/library/liked/toggle", { track });
    refreshState();
  };
  actions.appendChild(likeBtn);

  const queueBtn = document.createElement("button");
  queueBtn.textContent = "➕";
  queueBtn.title = "Add to queue";
  queueBtn.onclick = async (e) => {
    e.stopPropagation();
    await post("/api/queue/add", { track });
  };
  actions.appendChild(queueBtn);

  if (showRemove) {
    const removeBtn = document.createElement("button");
    removeBtn.textContent = "✕";
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

// ---------- now playing ----------

function renderNowPlaying(s) {
  state.current = s.currentTrack;
  document.getElementById("np-art").src = s.currentTrack ? s.currentTrack.thumbnailUrl || "" : "";
  document.getElementById("np-title").textContent = s.currentTrack ? s.currentTrack.title : "Nothing playing";
  document.getElementById("np-artist").textContent = s.currentTrack ? s.currentTrack.artist : "";
  document.getElementById("np-toggle").textContent = s.isPlaying ? "⏸" : "▶️";
  document.getElementById("np-shuffle").classList.toggle("active", !!s.isShuffling);

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

// ---------- tabs ----------

document.querySelectorAll(".tab-btn").forEach((btn) => {
  btn.onclick = () => {
    document.querySelectorAll(".tab-btn").forEach((b) => b.classList.remove("active"));
    document.querySelectorAll(".tab-panel").forEach((p) => p.classList.remove("active"));
    btn.classList.add("active");
    document.getElementById(`tab-${btn.dataset.tab}`).classList.add("active");
  };
});

document.querySelectorAll(".lib-btn").forEach((btn) => {
  btn.onclick = () => {
    document.querySelectorAll(".lib-btn").forEach((b) => b.classList.remove("active"));
    document.querySelectorAll(".lib-panel").forEach((p) => p.classList.remove("active"));
    btn.classList.add("active");
    document.getElementById(`lib-${btn.dataset.lib}`).classList.add("active");
    loadLibrarySection(btn.dataset.lib);
  };
});

// ---------- transport ----------

document.getElementById("np-toggle").onclick = () => post("/api/toggle").then(refreshState);
document.getElementById("np-next").onclick = () => post("/api/next").then(refreshState);
document.getElementById("np-prev").onclick = () => post("/api/previous").then(refreshState);
document.getElementById("np-shuffle").onclick = () => post("/api/shuffle").then(refreshState);

const seekEl = document.getElementById("np-seek");
seekEl.addEventListener("mousedown", () => (seekEl.dragging = true));
seekEl.addEventListener("touchstart", () => (seekEl.dragging = true));
seekEl.addEventListener("change", async () => {
  await post("/api/seek", { seconds: Number(seekEl.value) });
  seekEl.dragging = false;
  refreshState();
});

// ---------- home ----------

async function loadHome() {
  const tracks = await api("/api/home");
  renderList(document.getElementById("home-list"), tracks, {
    onPlay: (t) => post("/api/play", { track: t, context: tracks, contextTitle: "Quick Picks" }).then(refreshState),
  });
}

// ---------- search ----------

let searchTimer = null;
document.getElementById("search-input").addEventListener("input", (e) => {
  clearTimeout(searchTimer);
  const q = e.target.value;
  searchTimer = setTimeout(async () => {
    if (!q.trim()) {
      renderList(document.getElementById("search-list"), []);
      return;
    }
    const tracks = await api(`/api/search?q=${encodeURIComponent(q)}`);
    renderList(document.getElementById("search-list"), tracks, {
      onPlay: (t) => post("/api/play", { track: t, context: tracks, contextTitle: "Search" }).then(refreshState),
    });
  }, 350);
});

// ---------- library ----------

async function loadLibrarySection(section) {
  if (section === "liked") {
    const tracks = await api("/api/library/liked");
    renderList(document.getElementById("lib-liked"), tracks, {
      onPlay: (t) => post("/api/play", { track: t, context: tracks, contextTitle: "Liked Songs" }).then(refreshState),
    });
  } else if (section === "playlists") {
    const playlists = await api("/api/library/playlists");
    const container = document.getElementById("playlists-list");
    container.innerHTML = "";
    if (playlists.length === 0) {
      const empty = document.createElement("div");
      empty.className = "empty-hint";
      empty.textContent = "No playlists yet.";
      container.appendChild(empty);
    }
    playlists.forEach((p) => {
      const row = document.createElement("div");
      row.className = "track-row";
      const meta = document.createElement("div");
      meta.className = "track-meta";
      meta.innerHTML = `<div class="track-title">${escapeHtml(p.name)}</div><div class="track-artist">${p.tracks.length} songs</div>`;
      row.appendChild(meta);
      row.onclick = () => {
        renderList(document.getElementById("playlist-detail"), p.tracks, {
          onPlay: (t) => post("/api/play", { track: t, context: p.tracks, contextTitle: p.name }).then(refreshState),
        });
      };
      container.appendChild(row);
    });
  } else if (section === "radios") {
    const stations = await api("/api/library/radios");
    const container = document.getElementById("radios-list");
    container.innerHTML = "";
    if (stations.length === 0) {
      const empty = document.createElement("div");
      empty.className = "empty-hint";
      empty.textContent = "No radios yet — start one from the app.";
      container.appendChild(empty);
    }
    stations.forEach((station) => {
      const row = trackRow(station.seedTrack, {
        onPlay: async (seed) => {
          await post("/api/radio/play", { seedTrack: seed, shuffled: false });
          refreshState();
        },
      });
      row.querySelector(".track-title").textContent = `${station.seedTrack.title} Radio`;
      container.appendChild(row);
    });
  } else if (section === "downloads") {
    const tracks = await api("/api/library/downloads");
    renderList(document.getElementById("lib-downloads"), tracks, {
      onPlay: (t) => post("/api/play", { track: t, context: tracks, contextTitle: "Downloads" }).then(refreshState),
    });
  } else if (section === "daylist") {
    const daylist = await api("/api/library/daylist");
    document.getElementById("daylist-title").textContent = daylist.title || "Daylist";
    renderList(document.getElementById("daylist-list"), daylist.tracks, {
      onPlay: (t) => post("/api/play", { track: t, context: daylist.tracks, contextTitle: daylist.title }).then(refreshState),
    });
  }
}

document.getElementById("new-playlist-btn").onclick = async () => {
  const input = document.getElementById("new-playlist-name");
  const name = input.value.trim();
  if (!name) return;
  await post("/api/library/playlists/create", { name });
  input.value = "";
  loadLibrarySection("playlists");
};

document.getElementById("daylist-refresh").onclick = async () => {
  await post("/api/library/daylist/refresh");
  loadLibrarySection("daylist");
};

function escapeHtml(text) {
  const div = document.createElement("div");
  div.textContent = text;
  return div.innerHTML;
}

// ---------- live sync ----------

function connectWebSocket() {
  const ws = new WebSocket(`ws://${location.host}/ws`);
  ws.onmessage = (event) => {
    try {
      renderNowPlaying(JSON.parse(event.data));
    } catch (e) {
      /* ignore malformed frame */
    }
  };
  ws.onclose = () => setTimeout(connectWebSocket, 2000);
  ws.onerror = () => ws.close();
}

// ---------- init ----------

loadHome();
refreshState();
connectWebSocket();
setInterval(refreshState, 5000); // fallback in case the socket drops silently
