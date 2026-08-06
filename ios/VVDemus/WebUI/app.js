// Identifies this tab to the phone. Kept in sessionStorage rather than a plain variable
// so it survives a reload: the phone records which client owns "This Computer", and a
// reloaded tab that still has the same id silently reclaims casting. Without this, any
// reload (or navigating away and back) left the phone casting to a tab that no longer
// considered itself the cast tab — no audio anywhere, progress frozen, and no fallback
// either, since a socket was still connected.
/// Fisher-Yates.
///
/// This was `sort(() => Math.random() - 0.5)`, which is not a shuffle: a comparator that
/// returns random values isn't a consistent ordering, so the result is strongly biased
/// towards the original sequence and the bias varies by engine. The phone shuffles the
/// same list with `Array.shuffled()`, which is uniform — so the same button gave
/// measurably different results depending on which device you pressed it from.
function shuffle(items) {
  const out = [...items];
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [out[i], out[j]] = [out[j], out[i]];
  }
  return out;
}

function newClientId() {
  return Math.random().toString(36).slice(2) + Date.now().toString(36);
}

let CLIENT_ID = (() => {
  let id = sessionStorage.getItem("vvdemus_client_id");
  if (!id) {
    id = newClientId();
    sessionStorage.setItem("vvdemus_client_id", id);
  }
  return id;
})();

/// Guarantees the id is unique to this tab, which sessionStorage alone does not.
///
/// Chrome, Edge, Firefox and Safari all **copy** sessionStorage into the new tab on
/// "Duplicate Tab" (and on window.open from the page), so the clone starts life claiming
/// the original's identity. `isCastTab` is then true in both, both load the same stream
/// and call play(), and the same track comes out of the speakers twice a fraction of a
/// second apart — an audible flange — while both post progress reports under the one
/// clientId and the phone's position jitters between them.
///
/// Tabs announce their id on load; whichever was born later gives up its id and takes a
/// fresh one. The older tab keeps the id, so a genuine reload still reclaims casting.
const CLIENT_BORN_AT = Date.now() + Math.random();

(() => {
  if (!("BroadcastChannel" in window)) return;
  const channel = new BroadcastChannel("vvdemus_client_id");
  channel.onmessage = (e) => {
    const msg = e.data;
    if (!msg || msg.id !== CLIENT_ID) return;
    if (msg.type === "claim") {
      // Another tab is using our id. The older tab keeps it.
      if (CLIENT_BORN_AT < msg.bornAt) {
        channel.postMessage({ type: "taken", id: CLIENT_ID, bornAt: CLIENT_BORN_AT });
      }
    } else if (msg.type === "taken" && msg.bornAt < CLIENT_BORN_AT) {
      CLIENT_ID = newClientId();
      sessionStorage.setItem("vvdemus_client_id", CLIENT_ID);
      // This tab is no longer whoever the phone is casting to; stop producing sound.
      if (state.isCastTab) {
        state.isCastTab = false;
        releaseAudioElement();
        renderDeviceLabel();
      }
    }
  };
  channel.postMessage({ type: "claim", id: CLIENT_ID, bornAt: CLIENT_BORN_AT });
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
  // Whether the 1 Hz push is live. Snapshot freshness expectations depend on it: with the
  // socket down the only source is the 5 s poll.
  socketConnected: false,
  failedSrc: null,
  failedAt: 0,
  // Throttles re-resolve requests for a stream URL the browser could not play.
  streamFailureReportedFor: null,
  streamFailureReportedAt: 0,
  // Stall watchdog bookkeeping.
  lastObservedTime: -1,
  lastProgressAt: 0,
  // Set once the sidebar has been populated at least once; a first load that failed must
  // be retried rather than recorded as done.
  librarySignatureLoaded: false,
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
  // When the phone last answered anything — a socket frame, a poll, a command. See
  // refreshReachability: the banner is a question about elapsed silence, not about any one
  // request having failed.
  lastContactAt: Date.now(),
  // Stream URLs banked for tracks that haven't started yet, keyed by videoId, so this tab
  // can keep playing when the phone isn't there to hand it the next one. See
  // prefetchUpcomingStreams.
  streamBank: new Map(),
  // videoIds currently being resolved, so a request isn't made twice.
  streamBankInFlight: new Set(),
  // Tracks this tab played on its own while the phone was away. The phone still has them
  // at the front of its queue, so without this a second local advance would pick the same
  // track again. Cleared once the phone has caught up with where we got to.
  playedLocally: new Set(),
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
  // Three states of the same speaker, so the level is readable at a glance without
  // measuring the track. Same cone in all three; only the waves differ.
  volumeMute:
    '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M11 4.5v15l-5-4H3v-7h3zm3.5 3.4L16.9 10l2.4-2.1 1.3 1.5L18.4 11.5l2.2 2.1-1.3 1.5L16.9 13l-2.4 2.1-1.3-1.5 2.2-2.1-2.2-2.1z"/></svg>',
  volumeLow:
    '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M11 4.5v15l-5-4H3v-7h3zm3.2 4a4.5 4.5 0 0 1 0 7l-1-1.7a2.6 2.6 0 0 0 0-3.6z"/></svg>',
  volumeHigh:
    '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M11 4.5v15l-5-4H3v-7h3zm3.2 4a4.5 4.5 0 0 1 0 7l-1-1.7a2.6 2.6 0 0 0 0-3.6zm2.3-3a8.5 8.5 0 0 1 0 13l-1-1.7a6.6 6.6 0 0 0 0-9.6z"/></svg>',
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
    // Before the status check, deliberately: a 409 or a 400 is the phone disagreeing with
    // the request, which is just as much proof that it is awake and answering as a 200.
    // Every request funnels through here, so this is the one place reachability has to be
    // recorded — the poll is no longer the only thing that can clear the banner.
    noteContactWithPhone();
    if (!res.ok) throw new Error(`${path} -> ${res.status}`);
    const contentType = res.headers.get("content-type") || "";
    // `await`, not a bare `return` of the promise. Returning it from inside `try/finally`
    // runs the `finally` — and so `clearTimeout` — as soon as the promise is *created*,
    // which is the moment the headers arrive. The body download was then completely
    // unbounded: if the connection broke after the headers were flushed, this hung until
    // the OS TCP timeout, minutes later. That silently voided the 1500ms budget on the
    // `/api/next` call that the whole gapless-prefetch mechanism depends on, so instead of
    // continuing to the next track the music just stopped.
    return await (contentType.includes("application/json") ? res.json() : res.text());
  } finally {
    clearTimeout(timer);
  }
}

/// Tells the user something failed.
///
/// Almost every action in this file used to be fire-and-forget: a handler would `await` a
/// request, the request would time out against a briefly-busy phone, the rejection went
/// nowhere, and the UI simply did nothing. Silent no-ops are indistinguishable from a
/// click that didn't register, so people click again — which is how a slow refresh turns
/// into four queued mix fetches.
let toastTimer = null;

function showError(message) {
  let el = document.getElementById("toast");
  if (!el) {
    el = document.createElement("div");
    el.id = "toast";
    el.setAttribute("role", "status");
    el.setAttribute("aria-live", "polite");
    document.body.appendChild(el);
  }
  el.textContent = message;
  el.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove("show"), 4000);
}

/// Wraps a handler so a failure is reported rather than swallowed.
///
/// `AbortError` is reported as a timeout because that is what it always means here — the
/// only aborts are our own deadline firing.
function reporting(what, fn) {
  return async (...args) => {
    try {
      return await fn(...args);
    } catch (e) {
      const timedOut = e && (e.name === "AbortError" || /abort/i.test(String(e && e.message)));
      showError(timedOut ? `${what} timed out — is your phone awake?` : `${what} failed`);
      return undefined;
    }
  };
}

/// Makes a clickable `<div>` behave like a button for keyboard and screen-reader users.
///
/// Track rows, grid cards, radio chips and library rows are all divs with click handlers,
/// so none of them could take focus. Tabbing through search results stepped through each
/// row's Like and Add-to-queue buttons — two stops per result — while skipping the row
/// itself, so there was **no keyboard path to playing a song at all**, or to opening a
/// radio or a playlist. The right-click menu was unreachable for the same reason: a row
/// that can't be focused can't be sent Shift+F10.
function makeActivatable(el, label, activate) {
  el.tabIndex = 0;
  el.setAttribute("role", "button");
  if (label) el.setAttribute("aria-label", label);
  el.onclick = activate;
  el.addEventListener("keydown", (e) => {
    if (e.key !== "Enter" && e.key !== " " && e.key !== "Spacebar") return;
    // Leave the key alone if focus is on a nested control (Like, Add to queue) that has
    // its own activation behaviour — pressing Enter on the queue button must queue the
    // track, not play it.
    if (e.target !== el || (e.target.closest && e.target.closest("button") !== null)) return;
    // Space would otherwise scroll the list out from under the user.
    e.preventDefault();
    activate(e);
  });
}

/// Marks a control busy for the duration of an async action, so a slow phone can't be
/// turned into a queue of duplicate requests by an impatient second click.
async function withBusy(el, fn) {
  if (!el) return fn();
  if (el.dataset.busy === "1") return undefined;
  el.dataset.busy = "1";
  el.disabled = true;
  el.classList.add("busy");
  try {
    return await fn();
  } finally {
    delete el.dataset.busy;
    el.disabled = false;
    el.classList.remove("busy");
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

/// Escapes text for interpolation into markup — element content *or* an attribute value.
///
/// This used to be `div.textContent = text; return div.innerHTML`, which is the usual
/// trick and is only half a defence: serialising a text node escapes `&`, `<` and `>` but
/// leaves quotes untouched. Verified in a browser — feeding it `" onerror="..." x="` and
/// dropping the result into `src="..."` produced an element with a live `onerror`
/// attribute. Every current caller happened to be element content, so nothing was
/// exploitable through it, but `artImg` below does interpolate into an attribute and the
/// URLs it renders come from YouTube by way of whatever a POST wrote into the phone's
/// stored library.
const HTML_ESCAPES = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };

function escapeHtml(text) {
  return String(text ?? "").replace(/[&<>"']/g, (c) => HTML_ESCAPES[c]);
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

/// Markup for a thumbnail, or a placeholder glyph when the track has none.
///
/// `art()` returns "" for a missing thumbnail, and `<img src="">` does not render nothing:
/// the browser resolves the empty URL against the document, fetches this page's own HTML,
/// fails to decode it as an image and draws a broken-image icon. Radio seed tracks come
/// back from the phone with no `thumbnailUrl` at all, so that icon showed on the Home
/// shelf and in the sidebar on every load.
///
/// The URL is escaped because it comes from YouTube: a quote in it would otherwise close
/// the `src` attribute early and let the rest be parsed as markup.
function artImg(url, cssPixels, attrs = "") {
  const src = safeArtUrl(url, cssPixels);
  return src
    ? `<img src="${escapeHtml(src)}" alt="" ${attrs}>`
    : `<span class="art-fallback">${ICONS.note}</span>`;
}

/// Artwork URL, or "" if it isn't one we're willing to render.
///
/// Restricted to http(s) as defence in depth. These strings are not necessarily from
/// YouTube: any device on the network can POST a `Track` and the phone stores it verbatim,
/// so a `thumbnailUrl` is attacker-controlled input that gets persisted and re-rendered on
/// every later page load.
function safeArtUrl(url, cssPixels) {
  const src = art(url, cssPixels);
  return /^https?:\/\//i.test(src) ? src : "";
}

/// The same guard for an `<img>` element that already exists: hidden outright rather than
/// left with an empty `src`, so the container's own background shows instead of a broken
/// image.
function setArt(img, url, cssPixels) {
  const src = safeArtUrl(url, cssPixels);
  if (src) {
    img.src = src;
    img.hidden = false;
  } else {
    img.removeAttribute("src");
    img.hidden = true;
  }
}

// ---------- view switching ----------

/// The sidebar row that should stay lit for whatever is on screen.
///
/// Held here rather than set directly by the handlers because the sidebar navigates
/// *through* `openDetail`, which ends in `showView` — so a handler that highlighted its own
/// row first had the highlight wiped a moment later, and the sidebar never showed which
/// playlist or section you were looking at. Re-applied below after the clear.
let sidebarSelection = null;

function selectSidebarRow(el) {
  sidebarSelection = el;
}

/// Opens something from the sidebar, marking the row selected only if it actually opens.
///
/// The selection has to be set *before* the navigation, because the navigation ends in
/// `showView`, which is what applies it. But the row used to be painted selected up front
/// and left that way on failure: a timed-out fetch showed the sidebar claiming a section
/// was open while the content area still showed the previous one. Restoring the previous
/// selection on failure needs no DOM work — `showView` never ran, so nothing was repainted.
async function navigateFromSidebar(row, open) {
  const previous = sidebarSelection;
  selectSidebarRow(row);
  try {
    await open();
  } catch (e) {
    selectSidebarRow(previous);
    throw e;
  }
}

/// Whether the detail view is the one on screen.
///
/// `detail` itself is only ever reassigned by `openDetail`, so after visiting a radio once
/// it kept `kind === "radio"` forever. A pushed radio update then re-opened the detail
/// view from whatever the user had navigated to — mid-search, the page would navigate
/// itself and leave focus in a now-hidden input.
let detailVisible = false;

function showView(name) {
  document.querySelectorAll(".view").forEach((v) => v.classList.remove("active"));
  document.getElementById(`view-${name}`).classList.add("active");
  document.querySelectorAll(".nav-item").forEach((b) => b.classList.remove("active"));
  // Home and Search now exist twice — in the sidebar and in the narrow-width tab bar — so
  // the highlight is applied by destination rather than to the button that was clicked.
  // Marking only the clicked one left the wrong bar highlighted after a resize past 620px.
  document.querySelectorAll(`.nav-item[data-view="${name}"]`).forEach((b) => b.classList.add("active"));
  // Choosing a destination should dismiss the drawer it was chosen from.
  setLibraryDrawerOpen(false);
  document.querySelectorAll(".lib-shortcut, .library-row").forEach((b) => b.classList.remove("active"));
  // Guarded on still being in the document: the sidebar is rebuilt wholesale by
  // `loadLibraryList`, which would otherwise leave this holding a detached node.
  if (sidebarSelection && document.body.contains(sidebarSelection)) {
    sidebarSelection.classList.add("active");
  }
  // Each view has its own place in the list; carrying the last one's offset over meant
  // opening a playlist from the bottom of Home landed you mid-tracklist with the cover
  // art and the play button scrolled off above.
  const content = document.getElementById("content");
  if (content) content.scrollTop = 0;
  detailVisible = name === "detail";
}

document.querySelectorAll(".nav-item").forEach((btn) => {
  btn.onclick = () => {
    selectSidebarRow(null);
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

/// Forces the next reader to refetch. The phone folds the download count into
/// `librarySignature`, so a finished download is observable — it just wasn't being acted
/// on, leaving the menu offering "Download" for a track already on the device.
function invalidateDownloadsCache() {
  downloadsCache.at = 0;
}

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

/// Bumped every time the menu is opened or closed, so an async continuation started for
/// one track can detect that a different one has since taken over.
let contextMenuGeneration = 0;

function closeContextMenu() {
  contextMenuGeneration++;
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
//
// Scrolling *inside* the menu is exempt. The menu is deliberately scrollable
// (`max-height: 60vh; overflow-y: auto`), and a capture-phase listener on `document` sees
// scroll events from every descendant — so reaching a playlist below the fold closed the
// thing you were reaching into. Worse, it closed itself: showPlaylistPicker focuses its
// "New playlist" input, which scrolls the container to reveal it, so with enough playlists
// to overflow, "Add to Playlist" opened the picker and dismissed it in the same frame.
document.addEventListener(
  "scroll",
  (e) => {
    if (e.target instanceof Node && contextMenuEl.contains(e.target)) return;
    closeContextMenu();
  },
  true
);
window.addEventListener("resize", closeContextMenu);

function menuButton(label, icon, onClick, { liked } = {}) {
  const button = document.createElement("button");
  button.type = "button";
  button.setAttribute("role", "menuitem");
  button.innerHTML = `${icon}<span></span>`;
  button.querySelector("span").textContent = label;
  if (liked) button.classList.add("liked");
  // Wrapped here rather than at each of the dozen call sites. The menu is already closed by
  // the time the request is made, so a rejection had nowhere at all to show itself: "Play
  // Next", "Add to Queue", "Download" and the rest simply did nothing against a phone that
  // was a moment too slow.
  button.onclick = reporting(label, async (e) => {
    e.stopPropagation();
    closeContextMenu();
    await onClick();
  });
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
  playlistButton.onclick = reporting("Add to Playlist", async (e) => {
    e.stopPropagation();
    await showPlaylistPicker(track);
  });
  contextMenuEl.appendChild(playlistButton);

  const downloadSlot = document.createElement("div");
  contextMenuEl.appendChild(downloadSlot);

  if (onRemove) {
    contextMenuEl.appendChild(menuSeparator());
    contextMenuEl.appendChild(menuButton(removeLabel || "Remove from Queue", MENU_ICONS.trash, () => onRemove(track)));
  }

  // Stamped so a slow continuation can tell whether it still owns the menu.
  const generation = ++contextMenuGeneration;
  placeContextMenu(event.clientX, event.clientY);

  const downloaded = await downloadedIds();
  if (!contextMenuEl.classList.contains("open")) return; // closed while we waited
  // Checking "still open" was not enough: right-clicking track A and then track B before
  // this resolved let A's continuation append its Download row into a detached node and
  // then re-place the menu at A's coordinates, visibly teleporting B's menu to where A had
  // been clicked.
  if (generation !== contextMenuGeneration) return;
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
  back.onclick = reporting("Back", async (e) => {
    e.stopPropagation();
    await openTrackMenu(
      { preventDefault() {}, stopPropagation() {}, clientX: lastMenuPosition.x, clientY: lastMenuPosition.y },
      track
    );
  });
  contextMenuEl.appendChild(back);
  contextMenuEl.appendChild(menuSeparator());

  const listSlot = document.createElement("div");
  contextMenuEl.appendChild(listSlot);

  const newRow = document.createElement("div");
  const newInput = document.createElement("input");
  newInput.type = "text";
  newInput.placeholder = "New playlist name…";
  newInput.onclick = (e) => e.stopPropagation();
  newInput.onkeydown = (e) => {
    e.stopPropagation();
    if (e.key !== "Enter") return;
    const name = newInput.value.trim();
    if (!name) return;
    closeContextMenu();
    // Three chained requests with no error handling at all: if the middle one timed out
    // the playlist existed on the phone but the track was never added and the sidebar
    // never reloaded, so nothing on screen indicated it had half-happened. The menu is
    // already closed by this point, so the toast is the only possible feedback.
    reporting("Creating playlist", async () => {
      await post("/api/library/playlists/create", { name });
      // create doesn't hand back an id, so find the playlist it just made by name.
      const playlists = await api("/api/library/playlists");
      const created = playlists.find((p) => p.name === name);
      if (!created) throw new Error("created playlist not found");
      await post(`/api/library/playlists/${created.id}/add`, { track });
      await loadLibraryList();
      refreshOpenPlaylistDetail(created.id);
    })();
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
        await loadLibraryList();
        // The sidebar was rebuilt but the open detail view never was, so adding a song to
        // the playlist you were looking at didn't show it until you re-clicked the row.
        refreshOpenPlaylistDetail(playlist.id);
      })
    );
  });
  placeContextMenu(lastMenuPosition.x, lastMenuPosition.y);
  newInput.focus();
}

/// Re-opens the playlist detail view if it is the one currently on screen and its contents
/// just changed, so the track that was added actually appears.
async function refreshOpenPlaylistDetail(playlistId) {
  if (!detailVisible || detail.kind !== "playlist" || detail.playlistId !== playlistId) return;
  try {
    const playlists = await api("/api/library/playlists");
    const fresh = playlists.find((p) => p.id === playlistId);
    if (fresh) openPlaylistDetail(fresh);
  } catch (e) {
    /* the sidebar reload already reported any failure */
  }
}

/// Remembered so the picker (and the way back out of it) can reopen in the same spot.
let lastMenuPosition = { x: 0, y: 0 };

function attachTrackMenu(element, track, opts) {
  element.addEventListener("contextmenu", (e) => {
    lastMenuPosition = { x: e.clientX, y: e.clientY };
    openTrackMenu(e, track, opts);
  });
  // Keyboard equivalent. Without it the menu was unreachable without a mouse, since the
  // rows could not be focused at all before `makeActivatable`.
  element.addEventListener("keydown", (e) => {
    const wantsMenu = e.key === "ContextMenu" || (e.shiftKey && e.key === "F10");
    if (!wantsMenu || e.target !== element) return;
    e.preventDefault();
    const box = element.getBoundingClientRect();
    lastMenuPosition = { x: box.left + 24, y: box.top + box.height };
    openTrackMenu(
      { preventDefault() {}, stopPropagation() {}, clientX: lastMenuPosition.x, clientY: lastMenuPosition.y },
      track,
      opts
    );
  });

  // Touch equivalent, for driving the remote from a tablet.
  //
  // `longPressFired` exists because this listener cannot be non-passive without giving up
  // scroll performance, so it cannot `preventDefault()` the synthetic click the browser
  // emits on touchend. That click used to reach the row's own handler and the document's
  // dismiss handler: the menu appeared under your finger, then on lift the track started
  // playing and the menu vanished. Any deliberate, slow tap did it.
  let longPress = null;
  let longPressFired = false;
  element.addEventListener(
    "touchstart",
    (e) => {
      const touch = e.touches[0];
      longPressFired = false;
      longPress = setTimeout(() => {
        longPressFired = true;
        lastMenuPosition = { x: touch.clientX, y: touch.clientY };
        openTrackMenu({ preventDefault() {}, stopPropagation() {}, clientX: touch.clientX, clientY: touch.clientY }, track, opts);
      }, 500);
    },
    { passive: true }
  );
  // Capture phase, so it runs before the row's own click handler and before the
  // document-level dismiss.
  element.addEventListener(
    "click",
    (e) => {
      if (!longPressFired) return;
      longPressFired = false;
      e.stopPropagation();
      e.preventDefault();
    },
    true
  );
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
  setArt(img, track.thumbnailUrl, 44); // .track-row img is 44px
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
  // Reported rather than swallowed, like every other action. These were bare `await post`
  // calls in an async handler: a rejection went nowhere, so a like or a queue-add against a
  // briefly busy phone was indistinguishable from a click that never registered — and the
  // heart didn't move either, since the re-render waits on a state refresh that never came.
  likeBtn.onclick = reporting("Like", async (e) => {
    e.stopPropagation();
    await post("/api/library/liked/toggle", { track });
    await refreshState();
  });
  actions.appendChild(likeBtn);

  const queueBtn = document.createElement("button");
  queueBtn.innerHTML = ICONS.add;
  queueBtn.title = "Add to queue";
  queueBtn.onclick = reporting("Adding to queue", async (e) => {
    e.stopPropagation();
    await post("/api/queue/add", { track });
    await refreshState();
  });
  actions.appendChild(queueBtn);

  if (showRemove) {
    const removeBtn = document.createElement("button");
    removeBtn.innerHTML = ICONS.remove;
    removeBtn.title = "Remove";
    removeBtn.onclick = reporting("Removing", async (e) => {
      e.stopPropagation();
      await onRemove(track);
    });
    actions.appendChild(removeBtn);
  }

  row.appendChild(actions);
  makeActivatable(row, `Play ${track.title} by ${track.artist}`, () => onPlay && onPlay(track));
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

function openDetail(tracks, { title, subtitle, badge, imageURL, kind, seedTrack, showRefresh, playlistId }) {
  detail = {
    tracks,
    title,
    kind: kind || null,
    seedTrack: seedTrack || null,
    // Identifies *which* playlist is open, so a change to it can be reflected live.
    playlistId: playlistId || null,
  };

  document.getElementById("detail-badge").textContent = badge || "";
  document.getElementById("detail-title").textContent = title;
  document.getElementById("detail-subtitle").textContent = subtitle || "";
  // Escaped and scheme-checked like every other artwork site: `imageURL` reaches here
  // from a stored Track, which any device on the network can write.
  // 180 matches `.detail-art`; callers already size to the same number, so the resize is
  // a no-op and this is here for the escaping and the missing-artwork placeholder.
  document.getElementById("detail-art").innerHTML = artImg(imageURL, 180);
  document.getElementById("detail-refresh").style.display = showRefresh ? "flex" : "none";

  // Kept so the open list can be re-rendered when the playing track changes — otherwise
  // the highlight is frozen at whatever was playing when the view was opened, which is
  // why starting a radio never showed which song was playing.
  detail.rerender = () =>
    renderList(document.getElementById("detail-list"), tracks, {
      scope: `${kind || "detail"}:${title}`,
      onPlay: reporting("Play", async (t) => {
        await post("/api/play", { track: t, context: tracks, contextTitle: title, contextSeed: detail.seedTrack });
        await refreshState();
      }),
    });
  detail.rerender();
  showView("detail");
}

document.getElementById("detail-play").onclick = reporting("Play", async () => {
  if (!detail.tracks.length) return;
  await post("/api/play", {
    track: detail.tracks[0],
    context: detail.tracks,
    contextTitle: detail.title,
    contextSeed: detail.seedTrack,
  });
  await refreshState();
});

document.getElementById("detail-shuffle").onclick = reporting("Shuffle play", async () => {
  if (!detail.tracks.length) return;
  const shuffled = shuffle(detail.tracks);
  await post("/api/play", {
    track: shuffled[0],
    context: shuffled,
    contextTitle: detail.title,
    contextSeed: detail.seedTrack,
  });
  await refreshState();
});

// Busy-marked and error-reported. A refresh genuinely takes seconds (the phone goes out to
// YouTube), and with no busy state and no error surface the button looked broken: people
// clicked it repeatedly, each click starting another mix fetch, and a failure was
// indistinguishable from success.
{
  const refreshBtn = document.getElementById("detail-refresh");
  refreshBtn.onclick = reporting("Refresh", () =>
    withBusy(refreshBtn, async () => {
      if (detail.kind === "radio" && detail.seedTrack) {
        const tracks = await post("/api/radio/refresh", { videoId: detail.seedTrack.videoId }, CONTENT_TIMEOUT_MS);
        openRadioDetail(detail.seedTrack, tracks);
      } else if (detail.kind === "daylist") {
        await post("/api/library/daylist/refresh", {}, CONTENT_TIMEOUT_MS);
        await openDaylistDetail();
      }
    })
  );
}

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
    playlistId: playlist.id,
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
  btn.onclick = reporting("Opening", () =>
    withBusy(btn, () =>
      navigateFromSidebar(btn, async () => {
        const which = btn.dataset.detail;
        if (which === "daylist") await openDaylistDetail();
        else if (which === "liked") await openLikedDetail();
        else if (which === "downloads") await openDownloadsDetail();
      })
    )
  );
});

// ---------- device switching (VVDemus Connect) ----------

/// Opens/closes the device menu and keeps `aria-expanded` truthful.
///
/// The markup declares `role="menu"` with `menuitemradio` children, which promises roving
/// arrow-key focus — so that is implemented here rather than left as a claim the keyboard
/// doesn't honour. Below 860px the text label is hidden and this button is the only device
/// cue, which is why its `aria-label` carries the current device.
function setDeviceMenuOpen(open) {
  const menu = document.getElementById("np-device-menu");
  const btn = document.getElementById("np-device-btn");
  menu.classList.toggle("open", open);
  btn.setAttribute("aria-expanded", open ? "true" : "false");
  if (open) {
    const checked = menu.querySelector('[aria-checked="true"]') || menu.querySelector("button");
    if (checked) checked.focus();
  }
}

document.getElementById("np-device-btn").onclick = (e) => {
  e.stopPropagation();
  setDeviceMenuOpen(!document.getElementById("np-device-menu").classList.contains("open"));
};
document.addEventListener("click", () => setDeviceMenuOpen(false));

document.getElementById("np-device-menu").addEventListener("keydown", (e) => {
  const items = [...document.querySelectorAll("#np-device-menu button")];
  const i = items.indexOf(document.activeElement);
  if (e.key === "ArrowDown" || e.key === "ArrowUp") {
    e.preventDefault();
    const next = (i + (e.key === "ArrowDown" ? 1 : -1) + items.length) % items.length;
    items[next].focus();
  } else if (e.key === "Escape" || e.key === "Tab") {
    // Escape returns focus to the button; Tab closes and lets focus move on naturally.
    if (e.key === "Escape") e.preventDefault();
    setDeviceMenuOpen(false);
    if (e.key === "Escape") document.getElementById("np-device-btn").focus();
  }
});

// ---------- narrow-width library drawer ----------

/// Below 620px the sidebar becomes a slide-over. It has to be closable by every route a
/// user would try, and — because the scrim blocks clicks but not Tab — focus must not be
/// able to wander behind it.
function setLibraryDrawerOpen(open) {
  document.body.classList.toggle("library-open", open);
  const btn = document.getElementById("mobile-library-btn");
  if (btn) btn.setAttribute("aria-expanded", open ? "true" : "false");
}

{
  const drawerBtn = document.getElementById("mobile-library-btn");
  const scrim = document.getElementById("library-scrim");
  const drawer = document.getElementById("library-drawer");

  if (drawerBtn) {
    drawerBtn.onclick = (e) => {
      e.stopPropagation();
      setLibraryDrawerOpen(!document.body.classList.contains("library-open"));
    };
  }
  if (scrim) scrim.onclick = () => setLibraryDrawerOpen(false);

  document.addEventListener("keydown", (e) => {
    if (e.key !== "Escape" || !document.body.classList.contains("library-open")) return;
    setLibraryDrawerOpen(false);
    if (drawerBtn) drawerBtn.focus();
  });

  // Focus escaping the drawer is the one thing the scrim cannot prevent, so it is handled
  // here: anything focused outside the drawer while it is open closes it.
  if (drawer) {
    document.addEventListener("focusin", (e) => {
      if (!document.body.classList.contains("library-open")) return;
      if (drawer.contains(e.target) || e.target === drawerBtn) return;
      setLibraryDrawerOpen(false);
    });
  }
}
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

/// What this tab should play next with no help from the phone.
///
/// `state.upNext` is the phone's answer, prefetched with its URL, and it is authoritative
/// when it's there. But it only ever describes *one* track, and it isn't refilled while the
/// phone is away — so autonomy used to run out after exactly one song: the browser played
/// the prefetched track, `upNext` became null, and at the end of it there was nothing left
/// to reach for. The page went silent with a full queue on screen.
///
/// `state.streamBank` is the fallback: URLs for the next few queued tracks, banked while
/// the phone was still answering (see prefetchUpcomingStreams). Walking the same queue the
/// phone would walk — hand-queued tracks first, then the context queue — keeps a local
/// advance in the same order the phone would have chosen, so reconciling afterwards is a
/// no-op rather than a correction.
function nextTrackToPlayLocally() {
  const upNext = state.upNext;
  if (upNext && upNext.track && upNext.streamUrl) {
    return { track: upNext.track, streamUrl: upNext.streamUrl, fromUpNext: true };
  }
  const snapshot = state.last;
  if (!snapshot) return null;
  const queue = [...(snapshot.manualQueue || []), ...(snapshot.contextQueue || [])];
  for (const track of queue) {
    // Anything this tab has already played on its own is still sitting at the front of the
    // phone's queue — it doesn't know we consumed it yet. Skipping what we've played is
    // what keeps a long outage moving forward instead of looping the same track.
    if (state.playedLocally.has(track.videoId)) continue;
    const streamUrl = state.streamBank.get(track.videoId);
    if (streamUrl) return { track, streamUrl, fromUpNext: false };
    // Deliberately no `continue`: the queue is in play order, and skipping over a track
    // we have no URL for to reach one we do would play the album out of order. Better to
    // stop and let the phone sort it out when it's back.
    return null;
  }
  return null;
}

function playUpNextLocally() {
  const next = nextTrackToPlayLocally();
  if (!next) {
    // Genuinely nothing to play: the queue ran out, or the phone dropped before it could
    // tell us what was coming and there was nothing banked. The phone resyncs when it
    // returns; say so rather than just falling silent.
    if (state.playedWhileDisconnected) showError("Out of tracks until your phone is back");
    return;
  }
  audioEl.src = next.streamUrl;
  audioEl.load();
  state.loadedVideoId = next.track.videoId;
  state.loadedTrackEpoch = null; // no longer tracking the phone's load generation
  if (next.fromUpNext) state.upNext = null;
  state.streamBank.delete(next.track.videoId);
  state.playedLocally.add(next.track.videoId);
  // Remembered so the phone can be told what really happened once it answers again.
  state.playedWhileDisconnected = next.track.videoId;
  audioEl.addEventListener("ended", handleRealTrackEnded);
  playCastAudio();
  renderDeviceLabel();
}

/// How many tracks ahead this tab keeps a usable stream URL for.
///
/// Must not exceed the phone's own `maximumPrefetchDepth`, which refuses anything further
/// down the queue than it is willing to resolve.
const STREAM_BANK_DEPTH = 4;

/// Fills `state.streamBank` with URLs for the tracks coming up, so an outage that starts
/// mid-song doesn't end the music at the end of that song.
///
/// Only this tab's own upcoming queue, only while it is the one casting, and only once per
/// videoId — each miss is an InnerTube round trip on the phone. The phone would make the
/// same call when the track reached the front of the queue, and it caches by video id, so
/// what this really costs is making those calls earlier rather than more often.
///
/// Fire-and-forget by design: this is insurance, and a page that can't reach the phone to
/// buy it has nothing useful to do about that.
function prefetchUpcomingStreams(snapshot) {
  if (!state.isCastTab) return;
  const queue = [...(snapshot.manualQueue || []), ...(snapshot.contextQueue || [])];
  const wanted = queue.slice(0, STREAM_BANK_DEPTH).map((t) => t.videoId);

  // Anything no longer near the front has been played or skipped past. Dropping it keeps
  // the bank from growing for the life of the tab, and keeps a stale URL for a track the
  // user has moved past from being reachable at all.
  for (const videoId of [...state.streamBank.keys()]) {
    if (!wanted.includes(videoId)) state.streamBank.delete(videoId);
  }

  for (const videoId of wanted) {
    if (state.streamBank.has(videoId) || state.streamBankInFlight.has(videoId)) continue;
    // The phone resolves the very next track itself and ships the URL in the snapshot;
    // asking for it again would be a second round trip for a URL we already have.
    if (state.upNext && state.upNext.track && state.upNext.track.videoId === videoId) continue;
    state.streamBankInFlight.add(videoId);
    api(`/api/stream?videoId=${encodeURIComponent(videoId)}&clientId=${encodeURIComponent(CLIENT_ID)}`)
      .then((res) => {
        if (res && res.streamUrl) state.streamBank.set(videoId, res.streamUrl);
      })
      .catch(() => {
        // A 409 means the phone doesn't consider this track upcoming any more, which the
        // next snapshot will show. Nothing to recover.
      })
      .finally(() => state.streamBankInFlight.delete(videoId));
  }
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
    // The phone now agrees about what is playing, so its queue no longer contains the
    // tracks this tab consumed on its own and there is nothing left to skip over.
    state.playedLocally.clear();
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

    // Picking the device that is *already* active used to stop the music dead, and there
    // is nothing in the menu to say which one that is, so it was one stray click away at
    // any time. The silent unlock clip would replace the real audio, while the phone's
    // `setActiveDevice` early-returned without bumping any epoch — so the next snapshot
    // was identical, the reload branch never ran, and the element kept the silent clip
    // forever. Neither play/pause nor seek could recover it.
    // "This Computer" still has work to do when a *different* tab is casting — it takes
    // ownership — so this checks for this tab specifically, not merely for the computer
    // being the active device.
    const alreadyActive = device === "computer" ? state.isCastTab : state.activeDevice === "iphone";
    if (alreadyActive) return;

    const wasCastTab = state.isCastTab;
    state.isCastTab = device === "computer";
    state.needsGesture = false;
    if (state.isCastTab) {
      unlockAudioElementForGesture();
    } else {
      releaseAudioElement();
    }
    // clientId is what makes the phone able to name *this* tab as the cast client.
    //
    // Reported, and the optimistic local flip undone on failure. `isCastTab` is set above
    // so the tab starts producing sound the instant the phone confirms rather than a
    // broadcast tick later — but if the POST never lands, the phone has no idea this tab
    // claimed anything, and leaving the flag set left a tab that believed it was casting
    // while the phone played on by itself. Both devices, same song, a second apart.
    try {
      await post("/api/device", { device, clientId: CLIENT_ID });
      await refreshState();
    } catch (e) {
      state.isCastTab = wasCastTab;
      if (!state.isCastTab) releaseAudioElement();
      renderDeviceLabel();
      showError("Couldn't switch device — is your phone awake?");
    }
  };
});

/// play() is rejected when the browser hasn't been given a user gesture for this element
/// — which is exactly the situation after reclaiming casting on page load. Rather than
/// failing silently, arm a one-shot retry on the next click anywhere and say so in the
/// device label.
function playCastAudio() {
  suppressPlaybackEcho();
  const p = audioEl.play();
  if (p && p.catch) {
    p.catch((err) => {
      // Only a genuine autoplay block should arm the gesture retry. `play()` also rejects
      // with `AbortError` whenever a pending play is interrupted by `load()` or `pause()`,
      // which happens on completely ordinary paths — skipping twice quickly, or pausing
      // within a second of a track starting. Treating those as "blocked" put "Click
      // anywhere to resume" on screen *while music was playing perfectly*, and clicking it
      // then restarted audio the user had just paused for up to a second, which is exactly
      // the half-second of sound that stops AirPods handing over.
      if (err && err.name === "AbortError") return;
      armGestureRetry();
    });
  }
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
/// `playing` is passed in rather than read off the snapshot. Using raw `s.isPlaying` here
/// while every other indicator used the resolved value meant the tab title still showed
/// the track as playing after a media-key pause, for as long as the phone took to agree.
function renderDocumentTitle(s, playing) {
  const track = s && s.currentTrack;
  const next = !track
    ? "Spotify"
    : playing
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
  // Below 860px the label itself is hidden, so the button's accessible name is the only
  // device cue there is — it has to carry the state, not just the action.
  const btn = document.getElementById("np-device-btn");
  if (btn) {
    btn.setAttribute("aria-label", `Choose playback device — ${label.textContent.toLowerCase()}`);
  }
}

const volumeEl = document.getElementById("np-volume");
const volumeIconEl = document.getElementById("np-volume-icon");

function renderVolumeIcon(level) {
  const key = level <= 0 ? "volumeMute" : level < 0.5 ? "volumeLow" : "volumeHigh";
  // Guarded: this runs on every state broadcast, and reassigning innerHTML once a second
  // rebuilds the SVG for nothing.
  if (volumeIconEl.dataset.icon === key) return;
  volumeIconEl.dataset.icon = key;
  volumeIconEl.innerHTML = ICONS[key];
}

/// Keeps the slider, the icon and this tab's `<audio>` element on the phone's stored level.
///
/// The phone keeps one level per device, and the snapshot always carries the *active*
/// device's — so this slider is the computer's level while casting and the iPhone's while
/// the phone is playing, and switching devices makes it jump to the incoming device's
/// level. That is the point: it always adjusts whatever is actually making the sound.
function renderVolume(s) {
  // `dragging`/`committing` mirror the seek bar, and cover the audio element as well as
  // the thumb. Until the POST lands, every snapshot still carries the *pre-drag* level —
  // applied, it would drag the thumb back out from under the finger and, worse, audibly
  // fight it, since the `input` handler below has already set the real level.
  if (volumeEl.dragging || volumeEl.committing) return;
  const level = typeof s.volume === "number" ? s.volume : 1;
  if (s.activeDevice === "computer") audioEl.volume = level;
  volumeEl.value = Math.round(level * 100);
  renderVolumeIcon(level);
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
  // Tracked separately from `isCastTab`: when *another* tab is casting this one is not the
  // cast tab, but the active device is still the computer, and the device menu has to be
  // able to tell those apart.
  state.activeDevice = s.activeDevice;

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
    if (!s.streamUrl || s.streamVideoId !== videoId) {
      // Silence the outgoing track first. This `return` exits before the pause branch at
      // the bottom of the function, so for the 1-2s the phone spends resolving the new
      // URL the *previous* track carried on playing — the page showing track B with a
      // spinner while track A was still audible. Pressing pause during that window did
      // nothing for the same reason. The phone's own path pauses its engine here; the
      // browser had no equivalent.
      if (!audioEl.paused && state.loadedVideoId && state.loadedVideoId !== videoId) {
        suppressPlaybackEcho();
        audioEl.pause();
      }
      return;
    }
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
  if (!pending.retried && age > 2500) {
    // The request can simply have been lost. Ask again rather than letting audio the OS
    // stopped spring back to life — this failing towards "starts playing on its own" is
    // exactly what breaks an AirPods handover.
    //
    // The flag and the clock used to be set *before* this age test, one scope out. The
    // first snapshot that disagreed — which arrives within a second, since broadcasts are
    // 1 Hz and a `refreshState` is chased off the original POST — therefore consumed the
    // single retry without ever sending it, and no later snapshot could re-enter. So a
    // dropped toggle was never resent: the intent expired at 5s, the phone's stale
    // `isPlaying: true` won, and music the user had paused from the media keys started
    // again by itself about five seconds later.
    //
    // `pending.at` is deliberately not bumped here. Doing so also pushed back the 5s
    // expiry above, letting a stale intent outlive the window it was given.
    pending.retried = true;
    post("/api/toggle").then(refreshState).catch(() => {});
  }
  return pending.playing;
}

audioEl.addEventListener("pause", () => onPlaybackEcho(false));
audioEl.addEventListener("play", () => onPlaybackEcho(true));

/// Watches for playback that has quietly stopped moving.
///
/// A stalled element is `paused === false` and `ended === false`, so `syncCastAudio` takes
/// neither of its branches, no play/pause echo fires, and `timeupdate` stops — which means
/// progress reports stop too. The phone's only remaining signal is the tab's heartbeat,
/// which says "alive", so it never falls back either. The result was silence behind a
/// "playing" UI, indefinitely, with nothing on either side noticing. The phone has exactly
/// this watchdog for its own player; the browser had none.
const STALL_TIMEOUT_MS = 12000;

setInterval(() => {
  if (!state.isCastTab || !state.loadedVideoId) return;
  if (audioEl.paused || audioEl.ended) return;
  if (audioEl.currentSrc === SILENT_UNLOCK_SRC) return;

  const now = Date.now();
  const t = audioEl.currentTime;
  if (t !== state.lastObservedTime) {
    state.lastObservedTime = t;
    state.lastProgressAt = now;
    return;
  }
  if (!state.lastProgressAt) {
    state.lastProgressAt = now;
    return;
  }
  if (now - state.lastProgressAt < STALL_TIMEOUT_MS) return;

  // Buffering legitimately holds `currentTime` still. Distinguish it: if the element has
  // buffered past where it is sitting, this is not a network stall and nudging it is the
  // wrong move.
  let buffered = 0;
  try {
    for (let i = 0; i < audioEl.buffered.length; i++) {
      if (audioEl.buffered.start(i) <= t && t <= audioEl.buffered.end(i)) buffered = audioEl.buffered.end(i);
    }
  } catch (e) {
    /* buffered can throw before metadata */
  }
  state.lastProgressAt = now;
  if (buffered - t > 1) return;

  showError("Playback stalled — reloading the track");
  reportStreamFailure();
}, 2000);

// `waiting` and `stalled` are the browser telling us the same thing earlier; recording the
// moment keeps the watchdog above from counting buffering time twice.
["waiting", "stalled"].forEach((ev) =>
  audioEl.addEventListener(ev, () => {
    state.lastProgressAt = Date.now();
  })
);

audioEl.addEventListener("error", () => {
  // Lets the next state sync retry the load (e.g. a transiently expired/failed stream
  // URL) instead of leaving this videoId permanently marked "loaded" with nothing
  // actually playing. The URL that failed is remembered so the retry is throttled rather
  // than firing on every broadcast tick.
  if (!state.isCastTab) return;
  state.failedSrc = audioEl.getAttribute("src");
  state.failedAt = Date.now();
  state.loadedVideoId = null;
  reportStreamFailure();
});

/// Tells the phone the stream URL it gave us is dead, so it can re-resolve.
///
/// Without this the failure was terminal. The browser retried the *identical* URL every
/// 5 s forever: nothing on either side re-resolved it, the phone's own recovery path is
/// gated to `activeDevice == .iphone`, and `APIClient` serves the same string from its
/// cache until expiry anyway. Meanwhile the tab's WebSocket heartbeat kept
/// `computerIsReportingPlayback` true, so the phone never took playback back either.
/// One 403 — an expired URL after a long pause, or a phone resolving on cellular while the
/// computer fetches over Wi-Fi — meant silence behind a "Playing on This Computer" label
/// until the page was reloaded.
async function reportStreamFailure() {
  const videoId = state.last && state.last.currentTrack ? state.last.currentTrack.videoId : null;
  if (!videoId) return;
  // Throttled per track: a failing element can fire `error` repeatedly, and each report
  // makes the phone do a fresh network resolve.
  if (state.streamFailureReportedFor === videoId && Date.now() - (state.streamFailureReportedAt || 0) < 10000) {
    return;
  }
  state.streamFailureReportedFor = videoId;
  state.streamFailureReportedAt = Date.now();
  try {
    await post("/api/playback/stream-failed", { videoId, clientId: CLIENT_ID });
    // A fresh URL arrives in the next snapshot; clear the throttle so it is actually tried
    // rather than being suppressed as "the same failure".
    state.failedSrc = null;
    await refreshState();
  } catch (e) {
    // An older phone build has no such route. Nothing more to do — the existing 5s retry
    // stays as the fallback.
  }
}

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
  // Routed through the on-screen buttons rather than posting directly, so a media key gets
  // the same treatment a click does: the failure is reported, and play/pause and next still
  // work on this tab's own audio when the phone can't be reached. Pressing pause on the
  // keyboard and having nothing happen — while the music kept playing out of this very
  // machine — was the worst version of the silent-failure problem.
  const relayToggle = () => document.getElementById("np-toggle").onclick();
  const handlers = {
    play: relayToggle,
    pause: relayToggle,
    stop: relayToggle,
    nexttrack: () => document.getElementById("np-next").onclick(),
    previoustrack: () => document.getElementById("np-prev").onclick(),
    seekto: (details) => {
      if (typeof details.seekTime !== "number") return;
      suppressPlaybackEcho();
      audioEl.currentTime = details.seekTime;
      reporting("Seek", async () => {
        await post("/api/seek", { seconds: details.seekTime });
        await refreshState();
      })();
    },
    seekforward: (d) => seekRelative(d.seekOffset || 10),
    seekbackward: (d) => seekRelative(-(d.seekOffset || 10)),
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
  reporting("Seek", async () => {
    await post("/api/seek", { seconds: target });
    await refreshState();
  })();
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
  //
  // Scaled to how often snapshots are actually arriving. With the WebSocket up they come
  // at 1 Hz and 4s is a generous margin, but with it down the only source is the 5s poll —
  // so *every* snapshot was older than the threshold and the bypass fired unconditionally,
  // switching the ordering guard off entirely at precisely the moment two `/api/state`
  // responses are most likely to be in flight together (each command chases its own
  // refresh). That restored the exact reordering this guard exists to prevent.
  const staleBypassMs = state.socketConnected ? 4000 : 12000;
  if (state.lastAppliedAt && Date.now() - state.lastAppliedAt > staleBypassMs) return false;
  if (state.appliedEpoch === null || state.appliedEpoch === undefined) return false;
  if (s.playbackEpoch > state.appliedEpoch) return false;
  if (s.playbackEpoch < state.appliedEpoch) return true;
  // Same playback epoch: a lower trackLoadEpoch is still a snapshot from before the
  // current track was (re)started.
  return typeof s.trackLoadEpoch === "number" &&
    typeof state.appliedTrackLoadEpoch === "number" &&
    s.trackLoadEpoch < state.appliedTrackLoadEpoch;
}

/// Shared by both queue lists, which had the same three handlers written out twice — and
/// both copies dropped their rejections, so playing or removing a queued track against a
/// busy phone left the row sitting where it was with nothing said.
const queueRowActions = {
  onPlay: reporting("Play", async (t) => {
    await post("/api/queue/skip-to", { track: t });
    await refreshState();
  }),
  showRemove: true,
  onRemove: reporting("Removing", async (t) => {
    await post("/api/queue/remove", { track: t });
    await refreshState();
  }),
};

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
  // After syncCastAudio, which is what decides whether this tab is the one that would need
  // the URLs. Buying them is only useful while the phone is still there to sell them.
  prefetchUpcomingStreams(s);
  renderDeviceLabel();
  // After syncCastAudio, so a tab that just took over casting sets the level on an
  // element that already has its source.
  renderVolume(s);
  renderDocumentTitle(s, playing);
  const npArt = document.getElementById("np-art");
  setArt(npArt, s.currentTrack ? s.currentTrack.thumbnailUrl : null, 56);
  // The phone resolving a stream can take a second or two; without any sign of it, the
  // remote just looked frozen between pressing play and hearing anything.
  npArt.classList.toggle("loading", !!s.isLoading);
  document.getElementById("np-title").textContent = s.currentTrack ? s.currentTrack.title : "Nothing playing";
  document.getElementById("np-artist").textContent = s.currentTrack ? s.currentTrack.artist : "";
  document.getElementById("np-play-icon").style.display = playing ? "none" : "block";
  document.getElementById("np-pause-icon").style.display = playing ? "block" : "none";
  // The icon swap is invisible to a screen reader, so the label has to carry the state
  // too — otherwise the control announces "Play/Pause" regardless of what it will do.
  const toggleBtn = document.getElementById("np-toggle");
  toggleBtn.setAttribute("aria-label", playing ? "Pause" : "Play");
  toggleBtn.title = playing ? "Pause (Space)" : "Play (Space)";

  const shuffleBtn = document.getElementById("np-shuffle");
  shuffleBtn.classList.toggle("active", !!s.isShuffling);
  shuffleBtn.setAttribute("aria-pressed", s.isShuffling ? "true" : "false");

  const likeBtn = document.getElementById("np-like");
  const liked = s.currentTrack && (s.likedVideoIds || []).includes(s.currentTrack.videoId);
  likeBtn.innerHTML = liked ? ICONS.heartFilled : ICONS.heartOutline;
  likeBtn.setAttribute("aria-pressed", liked ? "true" : "false");
  likeBtn.setAttribute("aria-label", liked ? "Unlike" : "Like");
  likeBtn.title = liked ? "Unlike (L)" : "Like (L)";

  // Which device is active, reflected on the menu items.
  document.querySelectorAll("#np-device-menu button[data-device]").forEach((b) => {
    const isActive = b.dataset.device === (s.activeDevice === "computer" ? "computer" : "iphone");
    b.setAttribute("aria-checked", isActive ? "true" : "false");
  });
  likeBtn.classList.toggle("liked", !!liked);

  const seek = document.getElementById("np-seek");
  // `seeking` covers the window after the thumb is released while the POST is still in
  // flight. Without it, clearing `dragging` on `pointerup` would let a 1 Hz snapshot
  // carrying the pre-seek position overwrite the thumb, so it visibly snapped back and
  // then jumped forward again when the phone caught up.
  if (!seek.dragging && !seek.seeking) {
    seek.max = Math.max(s.duration, 1);
    seek.value = s.progress;
  }
  document.getElementById("np-elapsed").textContent = fmtTime(s.progress);
  document.getElementById("np-duration").textContent = fmtTime(s.duration);

  state.likedIds = new Set(s.likedVideoIds || []);

  renderList(document.getElementById("manual-queue-list"), s.manualQueue, queueRowActions);
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
  //
  // The signature is only recorded once the reload has actually *succeeded*. It used to be
  // stored unconditionally next to a fire-and-forget reload, so if either of its two 2s
  // requests missed the deadline the sidebar kept the old contents while the browser had
  // already written down the new signature — and it would not try again until the library
  // changed shape a second time. The new station simply never appeared.
  //
  // The `!== null` guard also meant the very first snapshot only *recorded* the signature,
  // so a failed initial `loadLibraryList()` left the sidebar empty for the life of the tab.
  // `librarySignatureLoaded` tracks that separately.
  if (s.librarySignature !== state.librarySignature || !state.librarySignatureLoaded) {
    const target = s.librarySignature;
    loadLibraryList()
      .then(() => {
        state.librarySignature = target;
        state.librarySignatureLoaded = true;
      })
      .catch(() => {
        // Left unrecorded on purpose: the next snapshot retries.
      });
  }

  // The signature also moves when a download finishes, and the reload above only refetches
  // playlists and radios — so the Downloads view and the context menu's Download/Remove
  // label went on showing stale information. Cheap to just drop the cache and let the next
  // reader refetch.
  if (s.librarySignature !== state.librarySignature) invalidateDownloadsCache();

  // Home only loads once; if that attempt failed, a reachable phone is the cue to retry.
  retryDeferredLoadsIfNeeded();

  renderList(document.getElementById("context-queue-list"), s.contextQueue, queueRowActions);
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

/// The same fetch, but tagged with this tab's id.
///
/// Used only by the periodic poll. A casting tab that is *paused* produces no other
/// attributable traffic — `timeupdate` doesn't fire on a paused element — so this is what
/// lets the phone distinguish "paused here" from "this browser is gone" without waiting
/// out a long timeout and pulling playback back to itself mid-session.
async function refreshStateIdentified() {
  const s = await api(`/api/state?clientId=${encodeURIComponent(CLIENT_ID)}`, {
    headers: { "X-VVDemus-Client-Id": CLIENT_ID },
  });
  renderNowPlaying(s);
}

// ---------- transport ----------

/// Play/pause, for a tab that is producing the sound and can't reach the phone.
///
/// The phone is the source of truth, so the button relays to it — but when it doesn't
/// answer, the music is still coming out of *this* tab's speakers and the user is entitled
/// to stop it. Without this the transport went dead the moment the phone did: audio playing,
/// every press swallowed, and no way to silence it short of closing the tab.
///
/// Only for the casting tab. Anywhere else there is nothing local to act on and pretending
/// otherwise would just put the page out of step with the phone.
function toggleLocally() {
  if (!state.isCastTab || !audioEl.getAttribute("src")) return false;
  suppressPlaybackEcho(); // our own doing, not the OS's — see onPlaybackEcho
  if (audioEl.paused) playCastAudio();
  else audioEl.pause();
  return true;
}

/// Relays a transport command, falling back to acting on this tab's own audio when the
/// phone can't be reached. `whenOffline` returning false means there was nothing local to
/// do, and the failure is reported as usual.
function transport(what, path, whenOffline) {
  return async () => {
    try {
      await post(path);
      await refreshState();
    } catch (e) {
      if (whenOffline && whenOffline()) return;
      showError(`${what} failed — is your phone awake?`);
    }
  };
}

document.getElementById("np-toggle").onclick = transport("Play/pause", "/api/toggle", toggleLocally);
document.getElementById("np-next").onclick = transport("Next", "/api/next", () => {
  // The same lifeline the end of a track uses: a banked URL for whatever is next. Skipping
  // is the most common thing to want during an outage and it used to be the one thing
  // guaranteed not to work.
  if (!state.isCastTab || !nextTrackToPlayLocally()) return false;
  playUpNextLocally();
  return true;
});
document.getElementById("np-prev").onclick = transport("Previous", "/api/previous");
document.getElementById("np-shuffle").onclick = transport("Shuffle", "/api/shuffle");
document.getElementById("np-like").onclick = reporting("Like", async () => {
  if (!state.current) return;
  await post("/api/library/liked/toggle", { track: state.current });
  await refreshState();
});

const seekEl = document.getElementById("np-seek");
seekEl.addEventListener("pointerdown", () => (seekEl.dragging = true));
// Without these, starting a drag and then releasing outside the slider (or letting the
// window lose focus mid-drag) left `dragging` stuck true forever — and while it's true
// the progress bar stops accepting updates from the phone, so the whole seek bar and
// elapsed time silently froze until the page was reloaded.
// `pointerup` is the one that actually matters and was the one missing. `change` only
// fires when the value really changed, so pressing the thumb and releasing without moving
// it — or dragging away and back to the same spot — left `dragging` latched true. The
// slider keeps focus, so `blur` didn't fire either, and the scrubber and elapsed time sat
// frozen while the music played on until the user happened to click elsewhere.
["pointerup", "pointercancel", "blur"].forEach((ev) =>
  seekEl.addEventListener(ev, () => (seekEl.dragging = false))
);
// Live feedback while scrubbing, instead of the elapsed time sitting still until release.
seekEl.addEventListener("input", () => {
  document.getElementById("np-elapsed").textContent = fmtTime(Number(seekEl.value));
});
seekEl.addEventListener("change", async () => {
  const seconds = Number(seekEl.value);
  seekEl.seeking = true;
  if (state.isCastTab && audioEl.src) audioEl.currentTime = seconds;
  try {
    await post("/api/seek", { seconds });
  } finally {
    // In a `finally`: if the POST times out, leaving this true freezes the scrubber and
    // the elapsed time until the page is reloaded, because renderNowPlaying skips seek-bar
    // updates while a drag is in progress.
    seekEl.dragging = false;
    seekEl.seeking = false;
    refreshState().catch(() => {});
  }
});

// The same `dragging` latch the seek bar needs, and for the same reason: while it is set,
// snapshots are not allowed to move the thumb, so a handler that fails to clear it freezes
// the control until the page is reloaded. `pointerup` is what actually ends a drag —
// `change` doesn't fire when the thumb is pressed and released without moving.
// Painted now rather than waiting for the first snapshot: the phone may be unreachable at
// load, and an empty box beside the slider reads as a broken control.
renderVolumeIcon(Number(volumeEl.value) / 100);

volumeEl.addEventListener("pointerdown", () => (volumeEl.dragging = true));
["pointerup", "pointercancel", "blur"].forEach((ev) =>
  volumeEl.addEventListener(ev, () => (volumeEl.dragging = false))
);

/// Debounces the write to the phone. The level is applied to this tab's `<audio>` element
/// on every `input` — instant and free — but the phone owns the stored value, and a single
/// drag fires dozens of these.
let volumePostTimer = null;

volumeEl.addEventListener("input", () => {
  const level = Number(volumeEl.value) / 100;
  if (state.last && state.last.activeDevice === "computer") audioEl.volume = level;
  renderVolumeIcon(level);
  // Held from the first `input` until the POST settles, so the window between releasing
  // the thumb and the phone agreeing is covered too — `dragging` alone ends at pointerup.
  volumeEl.committing = true;
  clearTimeout(volumePostTimer);
  volumePostTimer = setTimeout(() => {
    // Cleared in every outcome including a timeout: left set, renderVolume stops updating
    // the slider for good, so an unreachable phone would silently freeze the control.
    post("/api/volume", { volume: level })
      .catch(() => {})
      .finally(() => {
        volumeEl.committing = false;
      });
  }, 150);
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

  // Every one of these used to be a bare `post(...).then(refreshState)`: an unhandled
  // rejection whenever the phone was momentarily busy, and a keypress that silently did
  // nothing. They go through the same wrappers as the on-screen buttons now, so a failure
  // is reported and the ones with a local equivalent still work during an outage.
  const seekBy = (delta) => {
    const target = Math.max(0, Math.min(Number(seekEl.max) || 0, (state.last ? state.last.progress : 0) + delta));
    if (state.isCastTab && audioEl.src) audioEl.currentTime = target;
    reporting("Seek", async () => {
      await post("/api/seek", { seconds: target });
      await refreshState();
    })();
  };

  switch (e.key) {
    case " ":
      e.preventDefault(); // otherwise the page scrolls
      document.getElementById("np-toggle").onclick();
      break;
    case "ArrowRight": e.preventDefault(); seekBy(10); break;
    case "ArrowLeft": e.preventDefault(); seekBy(-10); break;
    case "n": case "N": document.getElementById("np-next").onclick(); break;
    case "p": case "P": document.getElementById("np-prev").onclick(); break;
    case "s": case "S": document.getElementById("np-shuffle").onclick(); break;
    case "l": case "L":
      document.getElementById("np-like").onclick();
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
      ${artImg(track.thumbnailUrl, 170, 'loading="lazy"')}
      <button class="g-queue-btn" title="Add to queue">${ICONS.add}</button>
    </div>
    <div class="g-title">${escapeHtml(track.title)}</div>
    <div class="g-artist">${escapeHtml(track.artist)}</div>
  `;
  card.querySelector(".g-queue-btn").onclick = reporting("Adding to queue", async (e) => {
    e.stopPropagation();
    await post("/api/queue/add", { track });
  });
  makeActivatable(
    card,
    `Play ${track.title} by ${track.artist}`,
    reporting("Play", async () => {
      await post("/api/play", { track, context: tracks, contextTitle });
      await refreshState();
    })
  );
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
      ${artImg(station.seedTrack.thumbnailUrl, 64, 'loading="lazy"')}
      <span class="r-title">${escapeHtml(station.seedTrack.title)} Radio</span>
    `;
    // Busy-marked: a radio fetch goes out to YouTube and can take seconds, during which
    // the chip used to give no sign at all — so people clicked it repeatedly and each
    // click started another fetch.
    makeActivatable(
      chip,
      `Open ${station.seedTrack.title} Radio`,
      reporting("Opening radio", () =>
        withBusy(chip, async () => {
          const tracks = await api(
            `/api/radio?videoId=${encodeURIComponent(station.seedTrack.videoId)}`,
            {},
            CONTENT_TIMEOUT_MS
          );
          openRadioDetail(station.seedTrack, tracks);
        })
      )
    );
    container.appendChild(chip);
  });
}

async function loadHomeRecommendations() {
  const container = document.getElementById("home-recommendations");
  // Fetch first, clear second. Clearing up front meant a failed reload destroyed a
  // perfectly good Home on the way to showing nothing.
  const sections = await api("/api/home", {}, CONTENT_TIMEOUT_MS);
  container.innerHTML = "";
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
  const results = await Promise.allSettled([loadHomeRadios(), loadHomeRecommendations()]);
  homeLoaded = results.every((r) => r.status === "fulfilled");
  renderHomeRetry();
  return homeLoaded;
}

/// Whether Home has ever loaded successfully in this tab.
///
/// `loadHome()` ran exactly once at startup with its rejection discarded, and nothing ever
/// re-ran it — not the WebSocket reconnect, not the 5s poll. So a phone that was asleep or
/// briefly without internet at page load left Home permanently empty: no content, no
/// error, no retry, and the internet coming back changed nothing. Only a manual reload
/// helped. Now a failure is visible, retryable by hand, and retried automatically the next
/// time the phone is known to be reachable.
let homeLoaded = false;
let homeRetryScheduled = false;

function renderHomeRetry() {
  const container = document.getElementById("home-recommendations");
  const existing = document.getElementById("home-retry");
  if (homeLoaded) {
    if (existing) existing.remove();
    return;
  }
  if (existing) return;
  const box = document.createElement("div");
  box.id = "home-retry";
  box.className = "empty-hint";
  const text = document.createElement("span");
  text.textContent = "Couldn't load Home. ";
  const btn = document.createElement("button");
  btn.className = "link-button";
  btn.textContent = "Try again";
  btn.onclick = reporting("Loading Home", () => withBusy(btn, loadHome));
  box.appendChild(text);
  box.appendChild(btn);
  container.appendChild(box);
}

/// Retries the things that only load once, when there is fresh evidence the phone is
/// reachable. Called from the state path, which is the only place that knows.
function retryDeferredLoadsIfNeeded() {
  if (homeLoaded || homeRetryScheduled) return;
  homeRetryScheduled = true;
  loadHome()
    .catch(() => {})
    .finally(() => {
      homeRetryScheduled = false;
    });
}

// ---------- search ----------

let searchTimer = null;
/// Incremented per keystroke so a slow response for an older query can be discarded.
let searchGeneration = 0;

function runSearch(q) {
  clearTimeout(searchTimer);
  if (!q.trim()) {
    renderList(document.getElementById("search-list"), []);
    return;
  }
  const list = document.getElementById("search-list");
  // Debouncing only cancelled the *timer*, never an in-flight request, and there was no
  // ordering guard. Typing "abc", pausing, then "def" left both fetches running; if the
  // first was slower it rendered last and you were looking at results for "abc" with
  // "def" in the box. `renderList`'s signature is scoped per query, so it did not
  // deduplicate the stale render — it guaranteed it.
  const generation = ++searchGeneration;
  list.setAttribute("aria-busy", "true");
  searchTimer = setTimeout(async () => {
    try {
      const tracks = await api(`/api/search?q=${encodeURIComponent(q)}`, {}, CONTENT_TIMEOUT_MS);
      if (generation !== searchGeneration) return; // a newer query has since been typed
      renderList(list, tracks, {
        scope: `search:${q}`,
        onPlay: (t) =>
          reporting("Play", async () => {
            await post("/api/play", { track: t, context: tracks, contextTitle: "Search" });
            await refreshState();
          })(),
      });
    } catch (e) {
      if (generation !== searchGeneration) return;
      // Previously the old query's results just stayed on screen with the new query in the
      // box — actively misleading rather than merely empty.
      renderList(list, [], { scope: `search-failed:${q}` });
      showError("Search failed — is your phone awake?");
    } finally {
      if (generation === searchGeneration) list.removeAttribute("aria-busy");
    }
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
        <span class="lib-icon">${artImg(station.seedTrack.thumbnailUrl, 32, 'loading="lazy"')}</span>
        <span class="track-title-sm">${escapeHtml(station.seedTrack.title)} Radio</span>
      `;
      row.onclick = reporting("Opening radio", () =>
        withBusy(row, () =>
          navigateFromSidebar(row, async () => {
            const tracks = await api(
              `/api/radio?videoId=${encodeURIComponent(station.seedTrack.videoId)}`,
              {},
              CONTENT_TIMEOUT_MS
            );
            openRadioDetail(station.seedTrack, tracks);
          })
        )
      );
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
      row.innerHTML = `
        <span class="lib-icon">${artImg(p.tracks[0] ? p.tracks[0].thumbnailUrl : null, 32, 'loading="lazy"')}</span>
        <span class="track-title-sm">${escapeHtml(p.name)}<span class="row-sub">${p.tracks.length} songs</span></span>
      `;
      row.onclick = () => {
        selectSidebarRow(row);
        openPlaylistDetail(p); // synchronous — nothing to fail
      };
      container.appendChild(row);
    });
  }
}

{
  const createBtn = document.getElementById("new-playlist-btn");
  const nameInput = document.getElementById("new-playlist-name");

  const createPlaylist = reporting("Creating playlist", () =>
    withBusy(createBtn, async () => {
      const name = nameInput.value.trim();
      if (!name) return;
      await post("/api/library/playlists/create", { name });
      nameInput.value = "";
      await loadLibraryList();
    })
  );

  createBtn.onclick = createPlaylist;
  // Enter in the field did nothing: the global key handler bails on any INPUT and there
  // was no per-field handler, even though the identical field in the track menu has always
  // submitted on Enter. Inconsistent within the same app, and Enter is the obvious thing
  // to press after typing a name.
  nameInput.addEventListener("keydown", (e) => {
    if (e.key !== "Enter") return;
    e.preventDefault();
    e.stopPropagation();
    createPlaylist();
  });
}

// ---------- live sync ----------

/// The socket this tab is currently living on, if any.
///
/// Nothing tracked it, and every path that could want a connection simply made one. The
/// consequences all pointed the same way — more sockets than the tab has any use for:
///
///   * `reconnectSocketNow` fires whenever the 5s poll succeeds and only checks
///     `socketConnected`, which is false for the whole time a socket sits in CONNECTING.
///     A phone that answers HTTP while the WebSocket handshake is slow therefore got a
///     brand new socket every five seconds.
///   * A superseded socket's `onclose` still ran the full handler, setting
///     `socketConnected = false`, painting the "can't reach your iPhone" banner and
///     scheduling *another* reconnect — while a perfectly healthy socket was open. So one
///     dead connection reliably produced a second live one, and so on.
///
/// Each stray socket holds one of the phone's 32 connection slots for as long as it lives
/// and runs its own 15s heartbeat, so this compounded into exactly the symptom it looked
/// like: a remote that keeps losing its connection.
let socket = null;
/// Abandons a socket that never finished connecting. Without this a handshake that hangs
/// (a phone that has gone to sleep answers neither the SYN nor a RST) leaves `socket`
/// non-null in CONNECTING for as long as the OS takes to give up — often a minute or more —
/// and `connectWebSocket` correctly refuses to replace it that whole time.
const SOCKET_CONNECT_TIMEOUT_MS = 8000;

function connectWebSocket() {
  // One socket per tab. `CONNECTING` counts: replacing a handshake in progress is how the
  // duplicates above got started.
  if (socket && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)) {
    return;
  }
  const ws = new WebSocket(`ws://${location.host}/ws`);
  socket = ws;
  let heartbeat = null;
  /// True once this socket has been replaced or deliberately abandoned. Its late events
  /// must not touch shared state — that is the second bullet above.
  const isCurrent = () => socket === ws;
  const connectTimer = setTimeout(() => {
    if (!isCurrent() || ws.readyState !== WebSocket.CONNECTING) return;
    // Dropped rather than left to hang. `close()` on a CONNECTING socket still fires
    // `onclose`, which schedules the retry.
    ws.close();
  }, SOCKET_CONNECT_TIMEOUT_MS);
  ws.onopen = () => {
    clearTimeout(connectTimer);
    if (!isCurrent()) {
      ws.close();
      return;
    }
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
    // Re-announces the moment the tab is looked at again. Browsers throttle timers in a
    // hidden tab to about once a minute, so the heartbeat above is not something the phone
    // can rely on for a backgrounded remote — the phone pings instead, and the browser
    // answers those in its networking stack without running any of this. What the pings
    // cannot carry is *which tab* the socket belongs to, and that is what the fall-back
    // decision hangs on, so the id is re-sent at the first moment this tab is live again.
    socketHello = hello;
    state.socketConnected = true;
    reconnectDelay = 1000;
    noteContactWithPhone();
    // Back in touch: if this tab kept playing without the phone, square that up now.
    reconcileAfterDisconnection();
  };
  ws.onmessage = (event) => {
    if (!isCurrent()) return;
    // A frame arrived, so the phone is demonstrably there. Nothing recorded that, so
    // reachability rested entirely on the 5s poll: with the socket delivering state ten
    // times over, one slow poll still painted "Can't reach your iPhone" across the top.
    noteContactWithPhone();
    try {
      const msg = JSON.parse(event.data);
      if (msg.type === "radio") {
        // A radio's mix changed (refreshed from the phone or another browser tab) —
        // if that's the one currently open here, update it live instead of going stale.
        //
        // `detailVisible` matters as much as the id: `detail` keeps describing the last
        // radio opened long after the user navigated away, so this used to re-open the
        // detail view over Search or Home the moment anyone refreshed that station.
        if (detailVisible && detail.kind === "radio" && detail.seedTrack && detail.seedTrack.videoId === msg.videoId) {
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
    clearTimeout(connectTimer);
    if (heartbeat) clearInterval(heartbeat);
    // A socket this tab has already moved on from. Letting it run the rest of this handler
    // is what turned one dead connection into a second live one: it cleared
    // `socketConnected` while another socket was open, and scheduled a reconnect that
    // `connectWebSocket` had no way to recognise as redundant.
    if (!isCurrent()) return;
    socket = null;
    socketHello = null;
    state.socketConnected = false;
    // Not `markPhoneUnreachable(true)`. The socket dropping says nothing about the phone on
    // its own — reconnects are routine, and the 5s poll usually keeps working right through
    // one. The banner is driven by how long it has been since *anything* got through.
    refreshReachability();
    // Backed off rather than a flat 2 s: a phone that's asleep, off the network or simply
    // switched off stays unreachable for hours, and hammering it every two seconds for
    // that whole time is pure battery on both ends.
    reconnectDelay = Math.min(reconnectDelay * 2, 30000);
    scheduleReconnect(reconnectDelay);
  };
  ws.onerror = () => ws.close();
}

/// Re-sends `hello:<id>` on the live socket, or nothing if there isn't one.
let socketHello = null;

let reconnectDelay = 1000;
let reconnectTimer = null;

function scheduleReconnect(delay) {
  clearTimeout(reconnectTimer);
  reconnectTimer = setTimeout(connectWebSocket, delay);
}

// Coming back to the tab is the cue to catch up on everything a throttled timer has been
// too slow to do: re-announce this tab to the phone, re-read the state, and stop waiting out
// a reconnect backoff that may have grown to half a minute while nobody was looking.
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState !== "visible") return;
  if (socketHello) socketHello();
  reconnectSocketNow();
  refreshState().catch(() => {});
});

/// Reconnects the socket now, because something else just proved the phone is reachable.
///
/// The backoff only ever grew. Resetting `reconnectDelay` in `markPhoneUnreachable` did
/// nothing to the timer already scheduled, so after a minute away the page would sit for
/// another 30s with the socket down — while its own 5s poll was succeeding and the UI
/// looked perfectly healthy. Everything socket-only was simply lost in that window,
/// including the lock-screen play/pause and seek relays, which are not retried anywhere:
/// scrubbing on the phone moved its own scrubber and the Mac never budged.
function reconnectSocketNow() {
  // A socket that is mid-handshake is not a reason to make another one; it is the single
  // most common reason a *second* one used to get made. `connectWebSocket` refuses either
  // way, but returning here also leaves the backoff alone rather than resetting it on
  // evidence the handshake in flight has not produced yet.
  if (socket && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)) return;
  reconnectDelay = 1000;
  scheduleReconnect(0);
}

/// How long everything — socket frames, polls, command responses — has to go unanswered
/// before the page says so.
///
/// The banner used to be a direct read of two events: the socket closing, and one 5s poll
/// rejecting. Both are things a healthy setup does regularly. A socket drops and reconnects
/// whenever the phone's Wi-Fi roams; a poll misses its 2s deadline whenever the phone is
/// briefly busy (every request has to reach the main thread, so a scroll or an artwork
/// decode is enough). Either one painted "Can't reach your iPhone" over a remote that went
/// on working perfectly, which is most of what "it keeps losing connection" looked like.
///
/// Long enough to cover a reconnect and a missed poll or two, short enough to still be
/// telling the truth by the time someone looks up at it.
const UNREACHABLE_AFTER_MS = 12000;

/// Records that the phone just answered something. Called from every transport, because
/// any one of them succeeding is proof.
function noteContactWithPhone() {
  state.lastContactAt = Date.now();
  refreshReachability();
}

/// Shows (or clears) the "can't reach your iPhone" state. Without it the page simply
/// froze on its last snapshot — still captioned "Playing on iPhone" — while every click
/// silently did nothing, which is indistinguishable from the app having hung.
function refreshReachability() {
  // `lastContactAt` starts at page load rather than at zero, so a fresh tab gets the same
  // grace as a running one instead of flashing the banner for the half second before its
  // first request lands.
  const unreachable = Date.now() - state.lastContactAt > UNREACHABLE_AFTER_MS;
  if (unreachable === state.phoneUnreachable) return;
  state.phoneUnreachable = unreachable;
  document.body.classList.toggle("phone-unreachable", unreachable);
  if (!unreachable) reconnectDelay = 1000;
}

// The banner has to be able to appear without anything happening, since "nothing is
// happening" is precisely the condition it reports. Every other call site is an event.
setInterval(refreshReachability, 2000);

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
  // Identified, so the phone can tell a *casting* tab that is merely paused from one that
  // has gone away. A paused element fires no `timeupdate`, so this poll is the only
  // attributable signal such a tab produces; without it the phone had to fall back to a
  // long timeout and would hand playback back to itself while the user was just paused.
  // Sent as both a query parameter and a header so the server can read whichever it
  // prefers. Every tab sends it, so the server attributes by id rather than assuming.
  refreshStateIdentified()
    .then(() => {
      noteContactWithPhone();
      // HTTP just worked, so the phone is back regardless of what the backoff thinks.
      reconnectSocketNow();
    })
    // No `markPhoneUnreachable(true)` here any more. One missed 2s deadline against a
    // briefly busy phone is not an outage, and treating it as one is why the banner
    // flickered on a remote that was working. `refreshReachability` decides on elapsed
    // silence instead, and runs on its own interval so it still fires when nothing does.
    .catch(() => refreshReachability());
}, 5000);
