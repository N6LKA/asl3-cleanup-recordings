#!/usr/bin/env python3
"""
ASL3 Audio Archive API
Serves AllStar transmission recordings with Allmon3 session authentication.
"""

import os
import re
from datetime import datetime
from pathlib import Path

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse

app = FastAPI()

RECORDINGS_DIR = Path(os.environ.get("RECORDINGS_DIR", "/recordings/501260"))
ALLMON3_AUTH_URL = "http://localhost:16080/auth/check"

_FILENAME_RE = re.compile(r"^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})\d{4}\.WAV$", re.IGNORECASE)
_SAFE_NAME_RE = re.compile(r"^[\w\-]+\.WAV$", re.IGNORECASE)


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
            return data == "Logged In" or (isinstance(data, dict) and data.get("SUCCESS") == "Logged In")
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
            "date": dt.strftime("%Y-%m-%d"),
            "time": dt.strftime("%H:%M"),
            "size": stat.st_size,
        })

    return JSONResponse(files)


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

    return FileResponse(
        file_path,
        media_type="audio/wav",
        headers={"Content-Disposition": f'inline; filename="{filename}"'},
    )
