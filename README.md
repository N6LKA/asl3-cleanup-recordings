# ASL3-Audio-Archive

![Release Version](https://img.shields.io/github/v/release/N6LKA/ASL3-Audio-Archive?label=Version&color=f15d24)
![License](https://img.shields.io/badge/license-GPLv3-lightgrey)

A web-based audio archive browser for AllStarLink 3 repeaters, integrated directly into [Allmon3](https://github.com/AllStarLink/Allmon3). Browse and play every archived transmission from your browser — no SSH required. Also includes the cleanup scheduler to automatically prune old recordings and keep disk usage under control.

---

## Features

- **In-browser playback** — listen to archived transmissions directly in Allmon3, including Chrome
- **Seamless authentication** — uses your existing Allmon3 login; no separate credentials
- **Auth-aware widget** — an optional iframe panel shows a link to the archive only when you are logged in to Allmon3
- **Automatic cleanup** — configurable cron job deletes recordings older than a set number of days

---

## Requirements

- AllStarLink 3 (ASL3) node with audio archiving enabled
- Allmon3 installed and running
- Python 3 with pip
- Root (sudo) access

---

## Installation

### Stable

```bash
curl -fsSL https://raw.githubusercontent.com/N6LKA/ASL3-Audio-Archive/main/install.sh | sudo bash
```

### Development / Testing

> ⚠️ **Warning:** `develop` may contain incomplete, untested, or broken features at any given time. Only use this on a system where you can tolerate things breaking (or reinstall from `main` to recover). Don't use it on a repeater or node you depend on for daily use.

```bash
curl -fsSL "https://github.com/N6LKA/ASL3-Audio-Archive/archive/refs/heads/develop.tar.gz" \
  | tar -xzO ASL3-Audio-Archive-develop/install.sh \
  | sudo bash -s -- --branch develop
```

---

## Post-Install Configuration

After the installer finishes, add one line to `/etc/allmon3/allmon3.ini` under your node section to enable the in-page widget:

```ini
[501260]
iframepost = recordings-widget.html
```

Then restart Allmon3:

```bash
sudo systemctl restart allmon3
```

The archive browser is available directly at:

```
http://<your-node>/allmon3/recordings-browser.html
```

---

## Cleanup Configuration

The cleanup scheduler config is at `/etc/asterisk/scripts/cleanup-recordings/cleanup-recordings.conf`. Edit `DAYS_TO_KEEP` to change the retention period:

```bash
# Number of days to retain recording files
DAYS_TO_KEEP=14
```

Run a test (no deletions) to preview what would be purged:

```bash
sudo /etc/asterisk/scripts/cleanup-recordings/cleanup-recordings.sh test
```

---

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/N6LKA/ASL3-Audio-Archive/main/uninstall.sh | sudo bash
```

The uninstaller removes the archive browser and backend service. It does **not** remove the cleanup script or any recordings.

---

## License

GPLv3 — see [LICENSE](LICENSE)

Author: Larry K. Aycock (N6LKA)
