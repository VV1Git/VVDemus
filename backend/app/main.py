"""
VVDemus backend — a small local API that the iOS app talks to.

Two jobs:
  1. Search / browse metadata via YouTube Music (ytmusicapi).
  2. Resolve a video ID to a direct, playable audio stream URL (yt-dlp).

Run for personal use only: `uvicorn app.main:app --host 0.0.0.0 --port 8000`
"""
from __future__ import annotations

from threading import Lock
from time import time

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from ytmusicapi import YTMusic
import yt_dlp

app = FastAPI(title="VVDemus Backend")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

yt = YTMusic()


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

def _thumb(thumbnails: list[dict] | None) -> str | None:
    if not thumbnails:
        return None
    return thumbnails[-1].get("url")


def _duration_seconds(entry: dict) -> int | None:
    seconds = entry.get("duration_seconds")
    if seconds is not None:
        return seconds
    text = entry.get("duration")
    if not text:
        return None
    parts = [int(p) for p in text.split(":")]
    total = 0
    for p in parts:
        total = total * 60 + p
    return total


def _to_track(entry: dict) -> Track | None:
    video_id = entry.get("videoId")
    if not video_id:
        return None
    artists = entry.get("artists") or []
    artist_name = ", ".join(a["name"] for a in artists if a.get("name")) or "Unknown Artist"
    album = entry.get("album")
    album_name = album.get("name") if isinstance(album, dict) else None
    return Track(
        videoId=video_id,
        title=entry.get("title", "Unknown Title"),
        artist=artist_name,
        album=album_name,
        thumbnailUrl=_thumb(entry.get("thumbnails")),
        durationSeconds=_duration_seconds(entry),
    )


# ---------- routes ----------

@app.get("/health")
def health():
    return {"ok": True}


@app.get("/search", response_model=list[Track])
def search(q: str, limit: int = 25):
    if not q.strip():
        raise HTTPException(400, "query is empty")
    results = yt.search(q, filter="songs", limit=limit)
    tracks = [t for t in (_to_track(r) for r in results) if t]
    return tracks


@app.get("/home", response_model=list[Track])
def home():
    """Quick picks for a default landing screen, since Demus needs no account."""
    seeds = ["top hits 2026", "chill mix", "trending music"]
    seen: set[str] = set()
    tracks: list[Track] = []
    for seed in seeds:
        for r in yt.search(seed, filter="songs", limit=10):
            t = _to_track(r)
            if t and t.videoId not in seen:
                seen.add(t.videoId)
                tracks.append(t)
    return tracks


@app.get("/playlist/{playlist_id}", response_model=list[Track])
def playlist(playlist_id: str):
    try:
        data = yt.get_playlist(playlist_id, limit=100)
    except Exception as exc:
        raise HTTPException(404, f"playlist not found: {exc}")
    tracks = [t for t in (_to_track(r) for r in data.get("tracks", [])) if t]
    return tracks


_stream_cache: dict[str, tuple[str, str, float]] = {}
_stream_cache_lock = Lock()


def _resolve_stream(video_id: str) -> tuple[str, str, float]:
    ydl_opts = {
        "format": "bestaudio/best",
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "extractor_args": {"youtube": {"player_client": ["android"]}},
    }
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(f"https://music.youtube.com/watch?v={video_id}", download=False)
    url = info["url"]
    mime = info.get("ext", "m4a")
    # YouTube signed URLs are time-limited; treat as expiring in 5 hours to be safe.
    expires_at = time() + 5 * 3600
    with _stream_cache_lock:
        _stream_cache[video_id] = (url, mime, expires_at)
    return url, mime, expires_at


@app.get("/stream/{video_id}", response_model=StreamInfo)
def stream(video_id: str):
    cached = _stream_cache.get(video_id)
    if cached and cached[2] > time():
        url, mime, expires_at = cached
    else:
        try:
            url, mime, expires_at = _resolve_stream(video_id)
        except Exception as exc:
            raise HTTPException(502, f"could not resolve stream: {exc}")
    return StreamInfo(videoId=video_id, url=url, expiresAt=expires_at, mimeType=mime)
