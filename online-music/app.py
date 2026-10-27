"""SelfMusic online-music sidecar (L1: search + verified download).

The sidecar wraps musicdl. It never returns upstream download URLs to clients:
search results carry an opaque token, and the audio is fetched/streamed only
through this service.
"""
from __future__ import annotations

import asyncio
import hmac
import json
import logging
import queue
import re
import shutil
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import uvicorn
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request
from fastapi.responses import FileResponse, PlainTextResponse, StreamingResponse
from pydantic import BaseModel

from config import Settings, load_settings, source_label
from verify import (
    AudioVerifyError,
    build_filename,
    ext_allowed,
    is_lossless,
    media_type,
    normalize_ext,
    verify_audio,
)

try:
    from musicdl import musicdl as musicdl_pkg
except Exception as exc:  # pragma: no cover - only hit when deps are missing
    musicdl_pkg = None
    MUSICDL_IMPORT_ERROR = exc
else:
    MUSICDL_IMPORT_ERROR = None

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(name)s - %(message)s",
)
logger = logging.getLogger("online-music")

SETTINGS: Settings = load_settings()
APP_VERSION = SETTINGS.version

app = FastAPI(title="SelfMusic Online Music", version=APP_VERSION)


# ---------------------------------------------------------------------------
# auth
# ---------------------------------------------------------------------------
def require_token(authorization: str | None = Header(default=None)) -> None:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="缺少 Bearer token")
    supplied = authorization[7:].strip()
    if not hmac.compare_digest(supplied, SETTINGS.token):
        raise HTTPException(status_code=401, detail="token 无效")


# ---------------------------------------------------------------------------
# musicdl client
# ---------------------------------------------------------------------------
_client_lock = threading.Lock()
_client: Any = None
_available_sources: tuple[str, ...] = ()


def get_client() -> Any:
    global _client, _available_sources
    if musicdl_pkg is None:
        raise HTTPException(
            status_code=503,
            detail=f"musicdl 未安装：{MUSICDL_IMPORT_ERROR}",
        )
    with _client_lock:
        if _client is None:
            cfg = {
                source: {
                    "search_size_per_source": SETTINGS.max_results_per_source,
                    "search_size_per_page": SETTINGS.max_results_per_source,
                    "work_dir": str(SETTINGS.work_dir),
                    "disable_print": True,
                    "max_retries": 2,
                    "maintain_session": False,
                }
                for source in SETTINGS.sources
            }
            try:
                client = musicdl_pkg.MusicClient(
                    music_sources=list(SETTINGS.sources),
                    init_music_clients_cfg=cfg,
                )
            except Exception as exc:
                raise HTTPException(
                    status_code=503, detail=f"musicdl 初始化失败：{exc}"
                ) from exc
            available = tuple(
                s for s in SETTINGS.sources if s in client.music_clients
            )
            if not available:
                raise HTTPException(
                    status_code=503, detail="没有可用的音乐源"
                )
            _client = client
            _available_sources = available
            logger.info("musicdl ready, sources=%s", ",".join(available))
        return _client


def available_sources() -> tuple[str, ...]:
    if not _available_sources:
        get_client()
    return _available_sources


# ---------------------------------------------------------------------------
# token registry
# ---------------------------------------------------------------------------
@dataclass
class TrackEntry:
    token: str
    source: str
    song_info: Any
    created_at: float = field(default_factory=time.time)


_tokens: dict[str, TrackEntry] = {}
_tokens_lock = threading.Lock()


def register_track(source: str, song_info: Any) -> str:
    token = uuid.uuid4().hex
    with _tokens_lock:
        _tokens[token] = TrackEntry(token=token, source=source, song_info=song_info)
    return token


def lookup_track(token: str) -> TrackEntry | None:
    now = time.time()
    with _tokens_lock:
        entry = _tokens.get(token)
        if entry is None:
            return None
        if now - entry.created_at > SETTINGS.token_ttl_s:
            _tokens.pop(token, None)
            return None
        return entry


# ---------------------------------------------------------------------------
# jobs
# ---------------------------------------------------------------------------
@dataclass
class Job:
    id: str
    source: str
    track_token: str
    title: str = ""
    artist: str = ""
    album: str = ""
    status: str = "queued"
    progress: float = 0.0
    downloaded_bytes: int = 0
    total_bytes: int = 0
    filename: str = ""
    ext: str = ""
    error: str = ""
    file_path: Path | None = None
    lrc_path: Path | None = None
    size_bytes: int = 0
    duration_s: float = 0.0
    sample_rate: int = 0
    channels: int = 0
    bit_depth: int = 0
    bitrate: int = 0
    created_at: float = field(default_factory=time.time)
    updated_at: float = field(default_factory=time.time)
    fetched_at: float | None = None

    def public(self) -> dict[str, Any]:
        return {
            "job_id": self.id,
            "status": self.status,
            "progress": round(min(1.0, max(0.0, self.progress)), 4),
            "downloaded_bytes": self.downloaded_bytes,
            "total_bytes": self.total_bytes,
            "source": self.source,
            "source_label": source_label(self.source),
            "title": self.title,
            "artist": self.artist,
            "album": self.album,
            "filename": self.filename,
            "ext": self.ext,
            "size_bytes": self.size_bytes,
            "duration_s": self.duration_s,
            "sample_rate": self.sample_rate,
            "channels": self.channels,
            "bit_depth": self.bit_depth,
            "bitrate": self.bitrate,
            "error": self.error,
            "has_lyric": bool(
                self.lrc_path and self.lrc_path.exists() and self.lrc_path.stat().st_size
            ),
        }


_jobs: dict[str, Job] = {}
_jobs_lock = threading.Lock()
_fetch_pool = ThreadPoolExecutor(
    max_workers=max(1, SETTINGS.max_fetches), thread_name_prefix="fetch"
)


def _update_job(job: Job, **fields: Any) -> None:
    with _jobs_lock:
        for key, value in fields.items():
            setattr(job, key, value)
        job.updated_at = time.time()


def _job_snapshot(job: Job) -> dict[str, Any]:
    with _jobs_lock:
        return job.public()


class NullProgress:
    """musicdl's `_search` only calls add_task/update; keep stdout clean."""

    def add_task(self, *args: Any, **kwargs: Any) -> int:
        return 0

    def update(self, *args: Any, **kwargs: Any) -> None:
        return None

    def advance(self, *args: Any, **kwargs: Any) -> None:
        return None

    def __getattr__(self, name: str):
        return lambda *args, **kwargs: None


class JobProgress(NullProgress):
    def __init__(self, job: Job):
        self.job = job

    def update(self, task_id: Any = None, **kwargs: Any) -> None:
        total = kwargs.get("total")
        completed = kwargs.get("completed")
        with _jobs_lock:
            if total:
                try:
                    self.job.total_bytes = int(total)
                except (TypeError, ValueError):
                    pass
            if completed:
                try:
                    self.job.downloaded_bytes = int(completed)
                except (TypeError, ValueError):
                    pass
            if self.job.total_bytes > 0:
                self.job.progress = min(
                    0.95, self.job.downloaded_bytes / self.job.total_bytes
                )
            self.job.updated_at = time.time()

    def advance(self, task_id: Any = None, advance: int = 0) -> None:
        with _jobs_lock:
            self.job.downloaded_bytes += max(0, int(advance or 0))
            if self.job.total_bytes > 0:
                self.job.progress = min(
                    0.95, self.job.downloaded_bytes / self.job.total_bytes
                )
            self.job.updated_at = time.time()


# ---------------------------------------------------------------------------
# search
# ---------------------------------------------------------------------------
SEARCH_LOCKS: dict[str, threading.Lock] = {}
SEARCH_LOCKS_LOCK = threading.Lock()


def _source_lock(source: str) -> threading.Lock:
    with SEARCH_LOCKS_LOCK:
        return SEARCH_LOCKS.setdefault(source, threading.Lock())


def _valid_result(song_info: Any) -> bool:
    if song_info is None or getattr(song_info, "episodes", None):
        return False
    if not getattr(song_info, "with_valid_download_url", False):
        return False
    url = getattr(song_info, "download_url", None)
    if not isinstance(url, str) or not url.startswith("http"):
        return False
    ext = normalize_ext(getattr(song_info, "ext", ""))
    return ext_allowed(ext)


def _track_payload(token: str, source: str, song_info: Any) -> dict[str, Any]:
    ext = normalize_ext(getattr(song_info, "ext", ""))
    lyric = getattr(song_info, "lyric", None) or ""
    if str(lyric).strip() in {"None", "NULL", "null"}:
        lyric = ""
    return {
        "track_token": token,
        "source": source,
        "source_label": source_label(source),
        "title": str(getattr(song_info, "song_name", "") or ""),
        "artist": str(getattr(song_info, "singers", "") or ""),
        "album": str(getattr(song_info, "album", "") or ""),
        "duration_s": int(getattr(song_info, "duration_s", 0) or 0),
        "ext": ext,
        "size_bytes": int(getattr(song_info, "file_size_bytes", 0) or 0),
        "lossless": is_lossless(ext),
        "has_lyric": bool(lyric),
    }


def _run_source_search(
    source: str,
    query: str,
    limit: int,
    emit,
    stop_event: threading.Event,
) -> None:
    client = get_client()
    emit(
        "source_start",
        {"source": source, "source_label": source_label(source)},
    )
    try:
        source_client = client.music_clients[source]
    except KeyError:
        emit("source_error", {"source": source, "message": "该音乐源不可用"})
        emit("source_done", {"source": source, "count": 0, "timed_out": False})
        return

    try:
        search_urls = source_client._constructsearchurls(
            keyword=query, rule={}, request_overrides={}
        )
    except Exception as exc:
        emit("source_error", {"source": source, "message": _safe_error(exc)})
        emit("source_done", {"source": source, "count": 0, "timed_out": False})
        return
    if not search_urls:
        emit("source_done", {"source": source, "count": 0, "timed_out": False})
        return

    bucket: list[Any] = []
    worker_error: list[Exception] = []

    def worker() -> None:
        lock = _source_lock(source)
        with lock:
            try:
                source_client._search(
                    keyword=query,
                    search_url=search_urls[0],
                    request_overrides={},
                    song_infos=bucket,
                    progress=NullProgress(),
                )
            except Exception as exc:  # pragma: no cover - defensive
                worker_error.append(exc)

    thread = threading.Thread(target=worker, name=f"search-{source}", daemon=True)
    thread.start()
    deadline = time.time() + SETTINGS.search_timeout_s
    seen: set[str] = set()
    cursor = 0
    emitted = 0
    timed_out = False
    while True:
        while cursor < len(bucket) and emitted < limit and not stop_event.is_set():
            song_info = bucket[cursor]
            cursor += 1
            if not _valid_result(song_info):
                continue
            identifier = str(getattr(song_info, "identifier", "") or "")
            if not identifier:
                identifier = "|".join(
                    [
                        str(getattr(song_info, "song_name", "") or ""),
                        str(getattr(song_info, "singers", "") or ""),
                        str(getattr(song_info, "ext", "") or ""),
                    ]
                )
            if identifier in seen:
                continue
            seen.add(identifier)
            token = register_track(source, song_info)
            emit("result", _track_payload(token, source, song_info))
            emitted += 1
        if emitted >= limit or stop_event.is_set():
            break
        if not thread.is_alive():
            break
        if time.time() > deadline:
            timed_out = True
            break
        time.sleep(0.1)
    # Final drain after the worker finished.
    while cursor < len(bucket) and emitted < limit and not stop_event.is_set():
        song_info = bucket[cursor]
        cursor += 1
        if not _valid_result(song_info):
            continue
        identifier = str(getattr(song_info, "identifier", "") or "")
        if not identifier:
            identifier = "|".join(
                [
                    str(getattr(song_info, "song_name", "") or ""),
                    str(getattr(song_info, "singers", "") or ""),
                    str(getattr(song_info, "ext", "") or ""),
                ]
            )
        if identifier in seen:
            continue
        seen.add(identifier)
        token = register_track(source, song_info)
        emit("result", _track_payload(token, source, song_info))
        emitted += 1
    if timed_out:
        logger.info("search timed out source=%s keyword=%s", source, query)
    if worker_error:
        logger.info(
            "search worker error source=%s: %s",
            source,
            _safe_error(worker_error[0]),
        )
    emit(
        "source_done",
        {"source": source, "count": emitted, "timed_out": timed_out},
    )


def _parse_sources(raw: str | None) -> list[str]:
    configured = list(available_sources())
    if not raw:
        return configured
    requested = [s.strip() for s in raw.split(",") if s.strip()]
    return [s for s in requested if s in configured]


@app.get("/v1/search")
async def search(
    request: Request,
    q: str = Query(..., min_length=1, max_length=100),
    sources: str | None = Query(default=None),
    limit: int = Query(default=10, ge=1, le=10),
    _: None = Depends(require_token),
):
    query = q.strip()
    if not query:
        raise HTTPException(status_code=400, detail="搜索关键词不能为空")
    selected = _parse_sources(sources)
    if not selected:
        raise HTTPException(status_code=400, detail="没有可用的音乐源")
    # Fail fast with 503 before starting an SSE response.
    get_client()

    async def event_generator():
        events: queue.Queue[tuple[str, Any]] = queue.Queue()
        stop_event = threading.Event()
        counter = {"results": 0}
        counter_lock = threading.Lock()

        def emit(event: str, data: Any) -> None:
            if event == "result":
                with counter_lock:
                    counter["results"] += 1
            events.put((event, data))

        def run() -> None:
            threads = []
            for source in selected:
                thread = threading.Thread(
                    target=_run_source_search,
                    args=(source, query, limit, emit, stop_event),
                    name=f"source-{source}",
                    daemon=True,
                )
                thread.start()
                threads.append(thread)
            for thread in threads:
                thread.join(timeout=SETTINGS.search_timeout_s + 5)
            events.put(("__done__", None))

        threading.Thread(target=run, name="search-coordinator", daemon=True).start()
        yield "retry: 10000\n\n"
        while True:
            if await request.is_disconnected():
                stop_event.set()
                break
            try:
                event, data = await asyncio.to_thread(events.get, True, 1.0)
            except queue.Empty:
                yield ": ping\n\n"
                continue
            if event == "__done__":
                with counter_lock:
                    total = counter["results"]
                yield (
                    "event: done\ndata: "
                    + json.dumps({"count": total}, ensure_ascii=False)
                    + "\n\n"
                )
                break
            yield (
                f"event: {event}\ndata: "
                + json.dumps(data, ensure_ascii=False)
                + "\n\n"
            )
        stop_event.set()

    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
            "Connection": "keep-alive",
        },
    )


# ---------------------------------------------------------------------------
# fetch / download
# ---------------------------------------------------------------------------
class FetchRequest(BaseModel):
    track_token: str


def _safe_error(exc: Exception | str) -> str:
    text = str(exc)
    text = re.sub(r"https?://\S+", "<url>", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text[:300] or "未知错误"


def _run_fetch(job: Job, entry: TrackEntry) -> None:
    info = entry.song_info
    try:
        ext = normalize_ext(getattr(info, "ext", ""))
        if not ext_allowed(ext):
            raise AudioVerifyError(f"不支持的音频格式：{ext or '未知'}")
        title = str(getattr(info, "song_name", "") or "未知曲目")
        artist = str(getattr(info, "singers", "") or "")
        album = str(getattr(info, "album", "") or "")
        filename = build_filename(title, artist, ext)
        job_dir = SETTINGS.fetch_dir / job.id
        job_dir.mkdir(parents=True, exist_ok=True)
        target = job_dir / filename
        info.work_dir = str(job_dir)
        info._save_path = str(target)
        _update_job(
            job,
            status="downloading",
            progress=0.01,
            title=title,
            artist=artist,
            album=album,
            filename=filename,
            ext=ext,
            file_path=target,
            total_bytes=int(getattr(info, "file_size_bytes", 0) or 0),
        )
        client = get_client()
        source_client = client.music_clients.get(job.source)
        if source_client is None:
            raise RuntimeError("音乐源不可用")
        downloaded: list[Any] = []
        progress = JobProgress(job)
        try:
            source_client._download(
                song_info=info,
                request_overrides={},
                downloaded_song_infos=downloaded,
                progress=progress,
                song_progress_id=0,
                auto_supplement_song=True,
            )
        except TypeError:
            # Keep working if musicdl's private signature changes.
            downloaded = source_client.download(
                song_infos=[info], num_threadings=1, auto_supplement_song=True
            )
        if not downloaded:
            downloaded = source_client.download(
                song_infos=[info], num_threadings=1, auto_supplement_song=True
            )
        if not downloaded:
            raise RuntimeError("下载失败（未得到有效文件）")
        actual = Path(str(getattr(downloaded[0], "save_path", "") or target))
        if not actual.exists():
            actual = target
        if not actual.exists():
            raise RuntimeError("下载完成后文件不存在")
        actual_ext = normalize_ext(actual.suffix)
        if not ext_allowed(actual_ext):
            raise RuntimeError(f"下载文件格式不受支持：{actual_ext or '未知'}")
        _update_job(
            job,
            status="verifying",
            progress=0.96,
            file_path=actual,
            filename=actual.name,
            ext=actual_ext,
            size_bytes=actual.stat().st_size,
        )
        info_json = verify_audio(
            actual, expected_duration_s=getattr(info, "duration_s", 0)
        )
        lrc = actual.with_suffix(".lrc")
        _update_job(
            job,
            status="ready",
            progress=1.0,
            file_path=actual,
            lrc_path=lrc if lrc.exists() and lrc.stat().st_size > 0 else None,
            size_bytes=actual.stat().st_size,
            duration_s=round(float(info_json.get("duration") or 0), 3),
            sample_rate=int(info_json.get("sample_rate") or 0),
            channels=int(info_json.get("channels") or 0),
            bit_depth=int(info_json.get("bit_depth") or 0),
            bitrate=int(info_json.get("bitrate") or 0),
        )
        logger.info(
            "fetch ready job=%s source=%s title=%s size=%s",
            job.id,
            job.source,
            job.title,
            job.size_bytes,
        )
    except Exception as exc:  # noqa: BLE001 - job boundary
        logger.exception("fetch failed job=%s source=%s", job.id, job.source)
        _update_job(job, status="error", error=_safe_error(exc), progress=0.0)
        # Do not keep partial/corrupt files around.
        try:
            shutil.rmtree(SETTINGS.fetch_dir / job.id, ignore_errors=True)
        except OSError:
            pass


@app.post("/v1/fetch", status_code=202)
def create_fetch(
    payload: FetchRequest,
    _: None = Depends(require_token),
):
    entry = lookup_track(payload.track_token)
    if entry is None:
        raise HTTPException(status_code=410, detail="曲目已过期，请重新搜索")
    info = entry.song_info
    job = Job(
        id=uuid.uuid4().hex,
        source=entry.source,
        track_token=payload.track_token,
        title=str(getattr(info, "song_name", "") or ""),
        artist=str(getattr(info, "singers", "") or ""),
        album=str(getattr(info, "album", "") or ""),
        ext=normalize_ext(getattr(info, "ext", "")),
    )
    with _jobs_lock:
        _jobs[job.id] = job
    _fetch_pool.submit(_run_fetch, job, entry)
    return _job_snapshot(job)


@app.get("/v1/fetch/{job_id}")
def fetch_status(job_id: str, _: None = Depends(require_token)):
    with _jobs_lock:
        job = _jobs.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="任务不存在或已过期")
    return _job_snapshot(job)


@app.get("/v1/fetch/{job_id}/file")
def fetch_file(job_id: str, _: None = Depends(require_token)):
    with _jobs_lock:
        job = _jobs.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="任务不存在或已过期")
    if job.status != "ready" or job.file_path is None:
        raise HTTPException(status_code=409, detail="任务尚未完成")
    path = job.file_path
    if not path.exists():
        raise HTTPException(status_code=410, detail="文件已清理，请重新下载")
    with _jobs_lock:
        job.fetched_at = time.time()
    return FileResponse(
        path,
        media_type=media_type(job.ext),
        filename=job.filename or path.name,
        headers={"Cache-Control": "no-store"},
    )


@app.get("/v1/fetch/{job_id}/lyric")
def fetch_lyric(job_id: str, _: None = Depends(require_token)):
    with _jobs_lock:
        job = _jobs.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="任务不存在或已过期")
    if job.lrc_path is None or not job.lrc_path.exists():
        raise HTTPException(status_code=404, detail="没有歌词")
    return PlainTextResponse(
        job.lrc_path.read_text(encoding="utf-8", errors="replace"),
        media_type="text/plain; charset=utf-8",
    )


# ---------------------------------------------------------------------------
# metadata / health
# ---------------------------------------------------------------------------
@app.get("/v1/sources")
def list_sources(_: None = Depends(require_token)):
    sources = available_sources()
    return {
        "sources": [
            {
                "id": source,
                "label": source_label(source),
                "default": source in SETTINGS.sources[:3],
            }
            for source in sources
        ]
    }


@app.get("/healthz")
def healthz():
    with _jobs_lock:
        active = sum(
            1
            for job in _jobs.values()
            if job.status in {"queued", "downloading", "verifying"}
        )
    return {
        "status": "ok" if musicdl_pkg is not None else "degraded",
        "version": APP_VERSION,
        "sources": list(SETTINGS.sources),
        "musicdl": musicdl_pkg is not None,
        "ffmpeg": bool(shutil.which("ffmpeg") and shutil.which("ffprobe")),
        "token_configured": bool(SETTINGS.token),
        "active_jobs": active,
    }


# ---------------------------------------------------------------------------
# cleanup
# ---------------------------------------------------------------------------
def _cleanup_loop() -> None:
    while True:
        time.sleep(60)
        now = time.time()
        with _tokens_lock:
            for token, entry in list(_tokens.items()):
                if now - entry.created_at > SETTINGS.token_ttl_s:
                    _tokens.pop(token, None)
        with _jobs_lock:
            expired = [
                job
                for job in _jobs.values()
                if job.status in {"ready", "error"}
                and now - job.updated_at > SETTINGS.job_ttl_s
            ]
            for job in expired:
                _jobs.pop(job.id, None)
            live_job_ids = set(_jobs.keys())
        for job in expired:
            shutil.rmtree(SETTINGS.fetch_dir / job.id, ignore_errors=True)
        # Remove orphaned dirs left by a crash.
        for child in SETTINGS.fetch_dir.iterdir():
            if child.is_dir() and child.name not in live_job_ids:
                try:
                    if now - child.stat().st_mtime > SETTINGS.job_ttl_s * 2:
                        shutil.rmtree(child, ignore_errors=True)
                except OSError:
                    pass


threading.Thread(target=_cleanup_loop, name="cleanup", daemon=True).start()


@app.on_event("startup")
def _log_startup() -> None:
    if SETTINGS.token_path is not None:
        logger.warning(
            "未设置 ONLINE_MUSIC_TOKEN，已生成 token：%s", SETTINGS.token_path
        )
    logger.info(
        "online-music sidecar %s, sources=%s, fetch_dir=%s",
        APP_VERSION,
        ",".join(SETTINGS.sources),
        SETTINGS.fetch_dir,
    )


if __name__ == "__main__":
    uvicorn.run(
        app,
        host=SETTINGS.host,
        port=SETTINGS.port,
        log_level="info",
        workers=1,
    )
