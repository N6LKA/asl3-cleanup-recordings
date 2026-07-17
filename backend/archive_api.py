#!/usr/bin/env python3
"""
ASL3 Audio Archive API
Serves AllStar transmission recordings with Allmon3 session authentication.
Converts GSM-encoded WAV files to PCM WAV on the fly for browser playback.
"""

import asyncio
import os
import re
import shutil
import subprocess
from datetime import datetime
from pathlib import Path

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import StreamingResponse, JSONResponse

app = FastAPI()

RECORDINGS_DIR   = Path(os.environ.get("RECORDINGS_DIR", "/recordings/501260"))
ALLMON3_AUTH_URL = "http://localhost:16080/auth/check"
SOX_BIN          = "/usr/bin/sox"
RPT_CONF         = Path("/etc/asterisk/rpt.conf")
CLEANUP_CONF     = Path("/etc/asterisk/scripts/cleanup-recordings/cleanup-recordings.conf")
CLEANUP_SCRIPT   = Path("/etc/asterisk/scripts/cleanup-recordings/cleanup-recordings.sh")
RUNNOW_FLAG      = Path("/tmp/allmon3-cleanup-runnow")

_FILENAME_RE  = re.compile(r"^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})\d{4}\.WAV$", re.IGNORECASE)
_SAFE_NAME_RE = re.compile(r"^[\w\-]+\.WAV$", re.IGNORECASE)
_duration_cache: dict[str, float] = {}


def _get_duration(wav: Path) -> float | None:
    if wav.name in _duration_cache:
        return _duration_cache[wav.name]
    try:
        result = subprocess.run(
            [SOX_BIN, "--i", "-D", str(wav)],
            capture_output=True, text=True, timeout=5,
        )
        dur = float(result.stdout.strip())
        _duration_cache[wav.name] = dur
        return dur
    except Exception:
        return None


# ── helpers ───────────────────────────────────────────────────────────────────

def _read_callsign(node_num: str) -> str | None:
    if not RPT_CONF.exists():
        return None
    try:
        content = RPT_CONF.read_text()
        m = re.search(
            r"^\[" + re.escape(node_num) + r"\][^\[]*?^callsign\s*=\s*(\S+)",
            content, re.MULTILINE | re.DOTALL | re.IGNORECASE,
        )
        if m:
            return m.group(1).upper().split(";")[0].strip()
    except Exception:
        pass
    return None


def _read_cleanup_conf() -> dict:
    defaults: dict = {
        "DAYS_TO_KEEP":       "14",
        "NODE":               "",
        "TARGET_DIR":         "",
        "SCHEDULE_FREQUENCY": "weekly",
        "SCHEDULE_DOW":       "0",
        "SCHEDULE_HOUR":      "3",
    }
    if not CLEANUP_CONF.exists():
        return defaults
    try:
        for line in CLEANUP_CONF.read_text().splitlines():
            line = line.strip()
            if line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            defaults[key.strip()] = val.strip().strip('"').strip("'")
    except Exception:
        pass
    return defaults


def _set_conf_field(content: str, key: str, value: str) -> str:
    if re.search(rf"^{key}=", content, re.MULTILINE):
        return re.sub(rf"^{key}=.*", f"{key}={value}", content, flags=re.MULTILINE)
    return content.rstrip("\n") + f"\n{key}={value}\n"


async def is_authenticated(request: Request) -> bool:
    cookies = request.headers.get("cookie", "")
    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(
                ALLMON3_AUTH_URL,
                headers={"Cookie": cookies},
                timeout=5.0,
            )
            data = r.json()
            return data == "Logged In" or (
                isinstance(data, dict) and data.get("SUCCESS") == "Logged In"
            )
    except Exception:
        return False


def parse_filename(name: str) -> datetime | None:
    m = _FILENAME_RE.match(name)
    if not m:
        return None
    try:
        return datetime(int(m[1]), int(m[2]), int(m[3]), int(m[4]), int(m[5]))
    except ValueError:
        return None


# ── endpoints ─────────────────────────────────────────────────────────────────

@app.get("/archive/api/info")
async def node_info(request: Request):
    if not await is_authenticated(request):
        raise HTTPException(status_code=401, detail="Unauthorized")
    node_num = RECORDINGS_DIR.name
    return JSONResponse({"node": node_num, "callsign": _read_callsign(node_num)})


@app.get("/archive/api/list")
async def list_recordings(request: Request):
    if not await is_authenticated(request):
        raise HTTPException(status_code=401, detail="Unauthorized")
    files = []
    for wav in sorted(RECORDINGS_DIR.glob("*.WAV"), reverse=True):
        dt = parse_filename(wav.name)
        if dt is None:
            continue
        stat = wav.stat()
        files.append({
            "filename": wav.name,
            "date":     dt.strftime("%Y-%m-%d"),
            "time":     dt.strftime("%H:%M"),
            "size":     stat.st_size,
            "duration": _get_duration(wav),
        })
    return JSONResponse(files)


@app.get("/archive/api/settings")
async def get_settings(request: Request):
    if not await is_authenticated(request):
        raise HTTPException(status_code=401, detail="Unauthorized")
    conf = _read_cleanup_conf()

    rec_size = sum(
        f.stat().st_size for f in RECORDINGS_DIR.glob("*.WAV") if f.is_file()
    ) if RECORDINGS_DIR.exists() else 0
    disk_free = disk_total = None
    try:
        du = shutil.disk_usage(RECORDINGS_DIR if RECORDINGS_DIR.exists() else Path("/"))
        disk_free  = du.free
        disk_total = du.total
    except Exception:
        pass

    return JSONResponse({
        "days_to_keep":       int(conf.get("DAYS_TO_KEEP", 14)),
        "node":               conf.get("NODE", ""),
        "target_dir":         conf.get("TARGET_DIR", ""),
        "schedule_frequency": conf.get("SCHEDULE_FREQUENCY", "weekly"),
        "schedule_dow":       int(conf.get("SCHEDULE_DOW", 0)),
        "schedule_hour":      int(conf.get("SCHEDULE_HOUR", 3)),
        "conf_exists":        CLEANUP_CONF.exists(),
        "script_exists":      CLEANUP_SCRIPT.exists(),
        "recordings_size":    rec_size,
        "disk_free":          disk_free,
        "disk_total":         disk_total,
    })


@app.post("/archive/api/settings")
async def save_settings(request: Request):
    if not await is_authenticated(request):
        raise HTTPException(status_code=401, detail="Unauthorized")

    body = await request.json()

    try:
        days = int(body["days_to_keep"])
        if not 1 <= days <= 365:
            raise ValueError
    except (KeyError, ValueError, TypeError):
        raise HTTPException(status_code=400, detail="days_to_keep must be 1–365")

    freq = str(body.get("schedule_frequency", "weekly")).lower()
    if freq not in ("daily", "weekly", "monthly"):
        raise HTTPException(status_code=400, detail="Invalid schedule_frequency")

    try:
        dow = int(body.get("schedule_dow", 0))
        if not 0 <= dow <= 6:
            raise ValueError
    except (ValueError, TypeError):
        raise HTTPException(status_code=400, detail="schedule_dow must be 0–6")

    try:
        hour = int(body.get("schedule_hour", 3))
        if not 0 <= hour <= 23:
            raise ValueError
    except (ValueError, TypeError):
        raise HTTPException(status_code=400, detail="schedule_hour must be 0–23")

    if not CLEANUP_CONF.exists():
        raise HTTPException(status_code=404, detail="Config file not found — re-run installer")

    try:
        content = CLEANUP_CONF.read_text()
        content = _set_conf_field(content, "DAYS_TO_KEEP",       str(days))
        content = _set_conf_field(content, "SCHEDULE_FREQUENCY",  freq)
        content = _set_conf_field(content, "SCHEDULE_DOW",        str(dow))
        content = _set_conf_field(content, "SCHEDULE_HOUR",       str(hour))
        CLEANUP_CONF.write_text(content)
    except PermissionError:
        raise HTTPException(status_code=500, detail="Permission denied — re-run installer to fix config permissions")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to write config: {e}")

    return JSONResponse({"status": "ok"})


@app.post("/archive/api/run-cleanup")
async def run_cleanup(request: Request):
    if not await is_authenticated(request):
        raise HTTPException(status_code=401, detail="Unauthorized")
    if not CLEANUP_SCRIPT.exists():
        raise HTTPException(status_code=404, detail="Cleanup script not found")
    try:
        RUNNOW_FLAG.touch(mode=0o644)
        return JSONResponse({"status": "triggered"})
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Could not signal daemon: {e}")


# ── audio serving ─────────────────────────────────────────────────────────────

async def stream_as_pcm(file_path: Path):
    """Convert GSM WAV to PCM WAV on the fly via sox and stream the result."""
    proc = await asyncio.create_subprocess_exec(
        SOX_BIN, str(file_path),
        "-t", "wav", "-r", "8000", "-e", "signed-integer", "-b", "16", "-c", "1", "-",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
    )

    async def generate():
        try:
            while True:
                chunk = await proc.stdout.read(32768)
                if not chunk:
                    break
                yield chunk
        finally:
            try:
                proc.kill()
            except ProcessLookupError:
                pass
            await proc.wait()

    return StreamingResponse(
        generate(),
        media_type="audio/wav",
        headers={"Content-Disposition": f'inline; filename="{file_path.name}"'},
    )


@app.get("/archive/api/file/{filename}")
async def serve_file(filename: str, request: Request):
    if not await is_authenticated(request):
        raise HTTPException(status_code=401, detail="Unauthorized")

    if not _SAFE_NAME_RE.match(filename):
        raise HTTPException(status_code=400, detail="Invalid filename")

    file_path = (RECORDINGS_DIR / filename).resolve()
    if not str(file_path).startswith(str(RECORDINGS_DIR.resolve())):
        raise HTTPException(status_code=400, detail="Invalid path")
    if not file_path.is_file():
        raise HTTPException(status_code=404, detail="Not found")

    return await stream_as_pcm(file_path)
