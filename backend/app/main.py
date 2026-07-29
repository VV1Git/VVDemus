"""
VVDemus backend — a small local API that the iOS app talks to.

Two jobs:
  1. Search / browse metadata via YouTube Music (ytmusicapi).
  2. Resolve a video ID to a direct, playable audio stream URL (yt-dlp).

Run for personal use only: `uvicorn app.main:app --host 0.0.0.0 --port 8000`
"""
from __future__ import annotations

import threading
from threading import Lock
from time import time

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from ytmusicapi import YTMusic
import yt_dlp

app = FastAPI(title="VVDemus Backend")

# Not "*". Every route is unauthenticated and the server is meant to be reachable on the
# LAN, so a wildcard origin let any page the user happened to visit drive this host's
# yt-dlp extractions from their browser — an open scraping proxy running on their machine.
app.add_middleware(
    CORSMiddleware,
    allow_origin_regex=r"^http://(localhost|127\.0\.0\.1)(:\d+)?$",
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)

# One YTMusic client per thread.
#
# Every route here is a plain `def`, so FastAPI runs it on an anyio worker thread — which
# is correct for a blocking library, but meant a single shared YTMusic instance was being
# used from up to 40 threads at once. It wraps a `requests.Session`, which is not
# thread-safe: concurrent use corrupts the shared connection pool and cookie jar, showing
# up as sporadic ConnectionErrors and occasionally a response handed to the wrong caller.
_thread_local = threading.local()


def _client() -> YTMusic:
    client = getattr(_thread_local, "yt", None)
    if client is None:
        client = YTMusic()
        _thread_local.yt = client
    return client


# ---------- response models ----------

class Track(BaseModel):
    videoId: str
    title: str
    artist: str
    album: str | None = None
    thumbnailUrl: str | None = None
    durationSeconds: int | None = None


class StreamInfo(BaseModel):
    videoId: str
    url: str
    expiresAt: float
    mimeType: str


# ---------- helpers ----------

def _thumb(entry: dict) -> str | None:
    # /search + /home results use "thumbnails"; get_watch_playlist (radio) uses "thumbnail".
    thumbnails = entry.get("thumbnails") or entry.get("thumbnail")
    # Shape-checked rather than assumed: some entry kinds carry a bare dict here, and
    # `thumbnails[-1]` on a dict raises KeyError and took the whole request down with it.
    if not isinstance(thumbnails, list) or not thumbnails:
        return None
    last = thumbnails[-1]
    return last.get("url") if isinstance(last, dict) else None


def _duration_seconds(entry: dict) -> int | None:
    seconds = entry.get("duration_seconds")
    if seconds is not None:
        return seconds
    # /search + /home use "duration"; get_watch_playlist (radio) uses "length".
    text = entry.get("duration") or entry.get("length")
    if not isinstance(text, str) or not text:
        return None
    # Shape-validated instead of `int(p)` straight into a list comprehension. These fields
    # are not always "m:ss" — live entries give "LIVE" and podcast episodes give
    # "1 hr 2 min" — and a single such row anywhere in a 25-result search raised
    # ValueError, escaped _to_track, and turned the entire search into a 500.
    parts = text.split(":")
    if not 1 <= len(parts) <= 3:
        return None
    total = 0
    for part in parts:
        part = part.strip()
        if not part.isdigit():
            return None
        total = total * 60 + int(part)
    return total


def _to_track(entry: dict) -> Track | None:
    if not isinstance(entry, dict):
        return None
    video_id = entry.get("videoId")
    if not video_id:
        return None
    artists = entry.get("artists") or []
    artist_name = ", ".join(
        a["name"] for a in artists if isinstance(a, dict) and a.get("name")
    ) or "Unknown Artist"
    album = entry.get("album")
    album_name = album.get("name") if isinstance(album, dict) else None
    return Track(
        videoId=str(video_id),
        title=entry.get("title", "Unknown Title"),
        artist=artist_name,
        album=album_name,
        thumbnailUrl=_thumb(entry),
        durationSeconds=_duration_seconds(entry),
    )


def _safe_track(entry) -> Track | None:
    """One malformed entry should cost that entry, not the whole response."""
    try:
        return _to_track(entry)
    except Exception:
        return None


def _tracks(entries) -> list[Track]:
    return [t for t in (_safe_track(e) for e in (entries or [])) if t]


# ---------- routes ----------

@app.get("/health")
def health():
    return {"ok": True}


@app.get("/search", response_model=list[Track])
def search(
    q: str = Query(..., min_length=1, max_length=200),
    limit: int = Query(25, ge=1, le=100),
):
    # Bounded: `limit` was unvalidated, and ytmusicapi walks continuation pages until it
    # runs out — `limit=100000` held an anyio worker for minutes.
    if not q.strip():
        raise HTTPException(400, "query is empty")
    try:
        results = _client().search(q, filter="songs", limit=limit)
    except Exception as exc:
        raise HTTPException(502, f"search failed: {exc}")
    return _tracks(results)


@app.get("/home", response_model=list[Track])
def home():
    """Quick picks for a default landing screen, since Demus needs no account."""
    seeds = ["top hits 2026", "chill mix", "trending music"]
    seen: set[str] = set()
    tracks: list[Track] = []
    client = _client()
    for seed in seeds:
        # One failing seed shouldn't empty the whole landing screen.
        try:
            results = client.search(seed, filter="songs", limit=10)
        except Exception:
            continue
        for t in _tracks(results):
            if t.videoId not in seen:
                seen.add(t.videoId)
                tracks.append(t)
    if not tracks:
        raise HTTPException(502, "could not load home feed")
    return tracks


@app.get("/playlist/{playlist_id}", response_model=list[Track])
def playlist(playlist_id: str):
    try:
        data = _client().get_playlist(playlist_id, limit=100)
    except Exception as exc:
        raise HTTPException(404, f"playlist not found: {exc}")
    return _tracks(data.get("tracks"))


@app.get("/radio/{video_id}", response_model=list[Track])
def radio(video_id: str, limit: int = Query(30, ge=1, le=100)):
    """YouTube Music's 'radio' for a track: the seed track followed by similar songs.
    Powers both the per-song Radio screen and autoplay continuation."""
    try:
        data = _client().get_watch_playlist(videoId=video_id, radio=True, limit=limit)
    except Exception as exc:
        raise HTTPException(404, f"radio not found: {exc}")
    return _tracks(data.get("tracks"))[:limit]


_stream_cache: dict[str, tuple[str, str, float]] = {}
_stream_cache_lock = Lock()


# Per-video locks, so twenty clients asking for the same track at once run one extraction
# between them rather than twenty.
_resolve_locks: dict[str, Lock] = {}
_resolve_locks_guard = Lock()

# How much of a URL's remaining life to insist on. Handing out a URL with two seconds left
# is the same as handing out a dead one by the time the client finishes connecting.
_EXPIRY_MARGIN = 300

_EXT_TO_MIME = {
    "m4a": "audio/mp4",
    "mp4": "audio/mp4",
    "webm": "audio/webm",
    "opus": "audio/opus",
    "mp3": "audio/mpeg",
}


def _real_expiry(info: dict, url: str) -> float:
    """The URL's actual deadline, not a guess.

    This used to be a flat `now + 5 hours`, invented rather than read. YouTube's signed
    URLs carry their real expiry in the `expire=` query parameter and it is frequently
    much shorter than five hours — so the cache kept serving a URL that had been dead for
    hours, and the client had no way to tell.
    """
    from urllib.parse import parse_qs, urlparse

    expire = parse_qs(urlparse(url).query).get("expire")
    if expire:
        try:
            return float(expire[0])
        except (TypeError, ValueError):
            pass
    seconds = info.get("streamingData", {}).get("expiresInSeconds") if isinstance(info, dict) else None
    try:
        if seconds is not None:
            return time() + float(seconds)
    except (TypeError, ValueError):
        pass
    return time() + 5 * 3600


def _resolve_stream(video_id: str) -> tuple[str, str, float]:
    ydl_opts = {
        "format": "bestaudio/best",
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        # Without a timeout a wedged extraction pins an anyio worker indefinitely; enough
        # of those and the server stops answering anything, /health included.
        "socket_timeout": 15,
        "extractor_args": {"youtube": {"player_client": ["android"]}},
    }
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(f"https://music.youtube.com/watch?v={video_id}", download=False)
    url = info["url"]
    # `ext` is a file extension, not a MIME type. The iOS download path branches on
    # `mimeType.hasPrefix("audio")`, and "m4a" never does — so every backend-resolved
    # download was being saved with the wrong extension.
    mime = _EXT_TO_MIME.get(info.get("ext", "m4a"), "audio/mp4")
    expires_at = _real_expiry(info, url)
    with _stream_cache_lock:
        _stream_cache[video_id] = (url, mime, expires_at)
        # Bounded: this grew for the lifetime of the process.
        if len(_stream_cache) > 512:
            oldest = sorted(_stream_cache.items(), key=lambda kv: kv[1][2])[:128]
            for key, _ in oldest:
                _stream_cache.pop(key, None)
    return url, mime, expires_at


def _cached_stream(video_id: str) -> tuple[str, str, float] | None:
    with _stream_cache_lock:
        cached = _stream_cache.get(video_id)
    if cached and cached[2] > time() + _EXPIRY_MARGIN:
        return cached
    return None


@app.get("/stream/{video_id}", response_model=StreamInfo)
def stream(video_id: str):
    cached = _cached_stream(video_id)
    if cached:
        url, mime, expires_at = cached
        return StreamInfo(videoId=video_id, url=url, expiresAt=expires_at, mimeType=mime)

    with _resolve_locks_guard:
        lock = _resolve_locks.setdefault(video_id, Lock())
    with lock:
        # Another caller may have resolved it while we waited.
        cached = _cached_stream(video_id)
        if cached:
            url, mime, expires_at = cached
        else:
            try:
                url, mime, expires_at = _resolve_stream(video_id)
            except Exception as exc:
                raise HTTPException(502, f"could not resolve stream: {exc}")
    return StreamInfo(videoId=video_id, url=url, expiresAt=expires_at, mimeType=mime)
