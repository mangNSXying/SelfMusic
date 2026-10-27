"""Audio verification and filename helpers."""
from __future__ import annotations

import json
import re
import shutil
import subprocess
from pathlib import Path
from typing import Any

from pathvalidate import sanitize_filename

ALLOWED_EXTS = {
    "mp3",
    "flac",
    "m4a",
    "aac",
    "ogg",
    "wav",
    "aif",
    "aiff",
    "aifc",
}
LOSSLESS_EXTS = {"flac", "wav", "aif", "aiff", "aifc", "alac"}

_EXT_FORMATS = {
    "mp3": {"mp3"},
    "flac": {"flac"},
    "m4a": {"mov", "mp4", "m4a", "3gp", "3g2", "mj2"},
    "aac": {"aac"},
    "ogg": {"ogg"},
    "wav": {"wav"},
    "aif": {"aiff"},
    "aiff": {"aiff"},
    "aifc": {"aiff"},
}
_EXT_CODECS = {
    "mp3": {"mp3"},
    "flac": {"flac"},
    "m4a": {"aac", "alac"},
    "aac": {"aac"},
    "ogg": {"vorbis", "opus", "flac"},
    "wav": None,
    "aif": None,
    "aiff": None,
    "aifc": None,
}
_MIME = {
    "mp3": "audio/mpeg",
    "flac": "audio/flac",
    "m4a": "audio/mp4",
    "aac": "audio/aac",
    "ogg": "audio/ogg",
    "wav": "audio/wav",
    "aif": "audio/aiff",
    "aiff": "audio/aiff",
    "aifc": "audio/aiff",
}


class AudioVerifyError(Exception):
    pass


def ffmpeg_available() -> bool:
    return bool(shutil.which("ffmpeg") and shutil.which("ffprobe"))


def normalize_ext(ext: str | None) -> str:
    return (ext or "").strip().lower().lstrip(".")


def ext_allowed(ext: str) -> bool:
    return ext in ALLOWED_EXTS


def is_lossless(ext: str) -> bool:
    return ext in LOSSLESS_EXTS


def media_type(ext: str) -> str:
    return _MIME.get(ext, "application/octet-stream")


def safe_component(value: str | None, fallback: str, limit: int = 90) -> str:
    raw = str(value or "")
    cleaned = sanitize_filename(raw, platform="universal", replacement_text="_")
    cleaned = re.sub(r"\s+", " ", cleaned).strip().strip(".")
    if not cleaned or cleaned in {".", ".."}:
        cleaned = fallback
    return cleaned[:limit].rstrip(" .") or fallback


def build_filename(title: str | None, artist: str | None, ext: str) -> str:
    ext = normalize_ext(ext)
    title_part = safe_component(title, "未知曲目", 100)
    artist_part = safe_component(artist, "", 70)
    stem = f"{title_part} - {artist_part}" if artist_part else title_part
    return f"{stem[:170].rstrip(' .')}.{ext}"


def probe_audio(path: Path) -> dict[str, Any]:
    if not shutil.which("ffprobe"):
        raise AudioVerifyError("sidecar 未安装 ffprobe")
    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-show_format",
        "-show_streams",
        "-of",
        "json",
        str(path),
    ]
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=60, check=False
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise AudioVerifyError(f"ffprobe 执行失败：{exc}") from exc
    if proc.returncode != 0:
        raise AudioVerifyError(f"ffprobe 无法解析：{(proc.stderr or '').strip()[:200]}")
    try:
        data = json.loads(proc.stdout or "{}")
    except json.JSONDecodeError as exc:
        raise AudioVerifyError("ffprobe 返回非法 JSON") from exc
    streams = data.get("streams") or []
    audio = next(
        (s for s in streams if s.get("codec_type") == "audio"), None
    )
    if audio is None:
        raise AudioVerifyError("文件不含音频流")
    fmt = data.get("format") or {}
    duration_raw = fmt.get("duration") or audio.get("duration")
    try:
        duration = float(duration_raw)
    except (TypeError, ValueError):
        duration = 0.0
    return {
        "duration": duration,
        "format_name": str(fmt.get("format_name") or ""),
        "codec": str(audio.get("codec_name") or ""),
        "sample_rate": int(audio.get("sample_rate") or 0),
        "channels": int(audio.get("channels") or 0),
        "bit_depth": int(
            audio.get("bits_per_raw_sample")
            or audio.get("bits_per_sample")
            or 0
        ),
        "bitrate": int(fmt.get("bit_rate") or audio.get("bit_rate") or 0),
        "size": int(fmt.get("size") or path.stat().st_size),
    }


def check_decode(path: Path) -> None:
    if not shutil.which("ffmpeg"):
        raise AudioVerifyError("sidecar 未安装 ffmpeg")
    cmd = [
        "ffmpeg",
        "-nostdin",
        "-hide_banner",
        "-v",
        "error",
        "-i",
        str(path),
        "-map",
        "0:a:0",
        "-f",
        "null",
        "-",
    ]
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=600, check=False
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise AudioVerifyError(f"ffmpeg 执行失败：{exc}") from exc
    errors = [line for line in (proc.stderr or "").splitlines() if line.strip()]
    if proc.returncode != 0 or errors:
        detail = errors[0][:220] if errors else f"退出码 {proc.returncode}"
        raise AudioVerifyError(f"音频解码校验失败：{detail}")


def verify_audio(path: Path, expected_duration_s: float | int | None = None) -> dict[str, Any]:
    if not path.exists() or not path.is_file():
        raise AudioVerifyError("下载文件不存在")
    if path.stat().st_size < 1024:
        raise AudioVerifyError("下载文件为空或过小")
    ext = normalize_ext(path.suffix)
    if not ext_allowed(ext):
        raise AudioVerifyError(f"不支持的音频格式：{ext or '未知'}")
    info = probe_audio(path)
    formats = {
        part.strip()
        for part in str(info["format_name"]).split(",")
        if part.strip()
    }
    if not formats.intersection(_EXT_FORMATS[ext]):
        raise AudioVerifyError(
            f"文件实际格式与扩展名不符：{info['format_name']} / .{ext}"
        )
    allowed_codecs = _EXT_CODECS.get(ext)
    if allowed_codecs is not None and info["codec"] not in allowed_codecs:
        raise AudioVerifyError(f"编解码器与扩展名不符：{info['codec']} / .{ext}")
    if info["duration"] <= 0:
        raise AudioVerifyError("无法读取音频时长")
    try:
        expected = float(expected_duration_s or 0)
    except (TypeError, ValueError):
        expected = 0.0
    if expected > 0 and abs(info["duration"] - expected) > 8:
        raise AudioVerifyError(
            f"音频时长异常：期望 {int(expected)}s，实际 {int(info['duration'])}s"
        )
    check_decode(path)
    return info
