#!/usr/bin/env python3
"""
allmon3-cleanup-daemon
Runs the recording cleanup on a configurable schedule.
Reads settings from cleanup-recordings.conf; responds within ~60 s to a
/tmp/allmon3-cleanup-runnow flag file dropped by the archive API.
Runs as root (required to delete Asterisk-owned recording files).
"""

import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

CONF_FILE      = Path("/etc/asterisk/scripts/cleanup-recordings/cleanup-recordings.conf")
CLEANUP_SCRIPT = Path("/etc/asterisk/scripts/cleanup-recordings/cleanup-recordings.sh")
RUNNOW_FLAG    = Path("/tmp/allmon3-cleanup-runnow")


def log(msg: str) -> None:
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"{ts}  {msg}", flush=True)


def read_conf() -> dict:
    defaults: dict = {
        "DAYS_TO_KEEP":        "14",
        "SCHEDULE_FREQUENCY":  "weekly",
        "SCHEDULE_DOW":        "0",
        "SCHEDULE_HOUR":       "3",
    }
    if not CONF_FILE.exists():
        return defaults
    try:
        for line in CONF_FILE.read_text().splitlines():
            line = line.strip()
            if line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            defaults[key.strip()] = val.strip().strip('"').strip("'")
    except Exception as e:
        log(f"WARNING: could not read conf: {e}")
    return defaults


def is_scheduled(conf: dict, now: datetime) -> bool:
    try:
        hour = int(conf.get("SCHEDULE_HOUR", "3"))
    except ValueError:
        return False
    if now.hour != hour:
        return False

    freq = conf.get("SCHEDULE_FREQUENCY", "weekly").lower()
    if freq == "daily":
        return True
    if freq == "weekly":
        try:
            cron_dow = int(conf.get("SCHEDULE_DOW", "0"))
        except ValueError:
            return False
        # cron: 0=Sunday; Python weekday(): 0=Monday, 6=Sunday
        python_dow = (cron_dow + 6) % 7
        return now.weekday() == python_dow
    if freq == "monthly":
        return now.day == 1
    return False


def do_cleanup() -> None:
    if not CLEANUP_SCRIPT.exists():
        log(f"ERROR: cleanup script not found at {CLEANUP_SCRIPT}")
        return
    log("Starting cleanup...")
    try:
        result = subprocess.run(
            [str(CLEANUP_SCRIPT)],
            capture_output=True,
            text=True,
            timeout=300,
        )
        for line in (result.stdout + result.stderr).splitlines():
            if line.strip():
                log(f"  {line}")
        log(f"Cleanup complete (exit {result.returncode})")
    except subprocess.TimeoutExpired:
        log("ERROR: cleanup script timed out after 300 s")
    except Exception as e:
        log(f"ERROR: {e}")


def main() -> None:
    log("allmon3-cleanup-daemon starting")
    if not CONF_FILE.exists():
        log(f"WARNING: config not found at {CONF_FILE} — using defaults")

    last_run_key: tuple | None = None  # (date, hour) prevents double-runs within same hour

    while True:
        try:
            # Immediate run via flag file (created by archive API "Run Now" button)
            if RUNNOW_FLAG.exists():
                try:
                    RUNNOW_FLAG.unlink()
                    log("Run-now flag detected")
                    do_cleanup()
                except Exception as e:
                    log(f"ERROR during flag-triggered run: {e}")

            # Scheduled run
            conf    = read_conf()
            now     = datetime.now()
            run_key = (now.date(), now.hour)

            if run_key != last_run_key and is_scheduled(conf, now):
                log("Scheduled run triggered")
                do_cleanup()
                last_run_key = run_key

        except Exception as e:
            log(f"ERROR in main loop: {e}")

        time.sleep(60)


if __name__ == "__main__":
    main()
