"""Sidecar configuration (environment driven)."""
from __future__ import annotations

import os
import secrets
from dataclasses import dataclass
from pathlib import Path

DEFAULT_SOURCES = ("QQMusicClient", "KuwoMusicClient", "MiguMusicClient")

SOURCE_LABELS = {
    "QQMusicClient": "QQ音乐",
    "KuwoMusicClient": "酷我音乐",
    "MiguMusicClient": "咪咕音乐",
    "KugouMusicClient": "酷狗音乐",
    "NeteaseMusicClient": "网易云音乐",
    "QianqianMusicClient": "千千音乐",
    "BilibiliMusicClient": "Bilibili音乐",
    "JamendoMusicClient": "Jamendo",
    "FMAMusicClient": "Free Music Archive",
    "AudiusMusicClient": "Audius",
    "CCMixterMusicClient": "ccMixter",
    "OpenGameArtMusicClient": "OpenGameArt",
    "WikimediaCommonsMusicClient": "Wikimedia Commons",
}


def source_label(source: str) -> str:
    return SOURCE_LABELS.get(source, source.removesuffix("MusicClient"))


def _env_int(name: str, default: int, minimum: int = 1) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        return max(minimum, int(raw))
    except ValueError:
        return default


def _read_or_create_token(state_dir: Path) -> tuple[str, Path | None]:
    raw = os.environ.get("ONLINE_MUSIC_TOKEN", "").strip()
    if raw:
        return raw, None
    token_path = state_dir / "token"
    if token_path.exists():
        token = token_path.read_text(encoding="utf-8").strip()
        if token:
            return token, token_path
    token = secrets.token_urlsafe(32)
    state_dir.mkdir(parents=True, exist_ok=True)
    token_path.write_text(token + "\n", encoding="utf-8")
    try:
        token_path.chmod(0o600)
    except OSError:
        pass
    return token, token_path


def _parse_sources() -> tuple[str, ...]:
    raw = os.environ.get("ONLINE_MUSIC_SOURCES", "").strip()
    if not raw:
        return DEFAULT_SOURCES
    sources = tuple(s.strip() for s in raw.split(",") if s.strip())
    return sources or DEFAULT_SOURCES


@dataclass(frozen=True)
class Settings:
    host: str
    port: int
    token: str
    token_path: Path | None
    sources: tuple[str, ...]
    state_dir: Path
    work_dir: Path
    fetch_dir: Path
    token_ttl_s: int
    job_ttl_s: int
    search_timeout_s: int
    max_fetches: int
    max_results_per_source: int
    version: str = "1.0.0"


def load_settings() -> Settings:
    state_dir = Path(
        os.environ.get("ONLINE_MUSIC_STATE_DIR", str(Path.cwd() / "state"))
    ).expanduser().resolve()
    fetch_dir = state_dir / "fetch"
    work_dir = state_dir / "work"
    for path in (state_dir, fetch_dir, work_dir):
        path.mkdir(parents=True, exist_ok=True)
    token, token_path = _read_or_create_token(state_dir)
    return Settings(
        host=os.environ.get("ONLINE_MUSIC_HOST", "0.0.0.0").strip() or "0.0.0.0",
        port=_env_int("ONLINE_MUSIC_PORT", 18090),
        token=token,
        token_path=token_path,
        sources=_parse_sources(),
        state_dir=state_dir,
        work_dir=work_dir,
        fetch_dir=fetch_dir,
        token_ttl_s=_env_int("ONLINE_MUSIC_TOKEN_TTL_MIN", 30) * 60,
        job_ttl_s=_env_int("ONLINE_MUSIC_JOB_TTL_MIN", 30) * 60,
        search_timeout_s=_env_int("ONLINE_MUSIC_SEARCH_TIMEOUT_SEC", 30),
        max_fetches=_env_int("ONLINE_MUSIC_MAX_FETCHES", 2),
        max_results_per_source=min(
            10, _env_int("ONLINE_MUSIC_MAX_RESULTS_PER_SOURCE", 10)
        ),
    )
