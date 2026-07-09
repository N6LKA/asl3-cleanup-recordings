# asl3-cleanup-recordings

![Release Version](https://img.shields.io/github/v/release/N6LKA/asl3-cleanup-recordings?label=Version&color=f15d24)
![Release Date](https://img.shields.io/github/release-date/N6LKA/asl3-cleanup-recordings?label=Released&color=f15d24)
![Hits](https://img.shields.io/endpoint?url=https%3A%2F%2Fhits.dwyl.com%2FN6LKA%2Fasl3-cleanup-recordings.json&label=Hits&color=f15d24)
![GitHub Repo Size](https://img.shields.io/github/repo-size/N6LKA/asl3-cleanup-recordings?label=Size&color=f15d24)

Automatically cleans old AllStar recording files from ASL3 nodes. Deletes `.WAV` and `.txt` recording files older than a configurable number of days, keeping your storage from filling up over time.

---

## Features

- Configurable retention period (number of days to keep)
- Configurable recording directory
- Configurable cron schedule for automatic cleanup
- **Test mode** — preview what would be deleted without removing anything
- Config file preserved across updates
- Simple one-line install and update

---

## Requirements

- ASL3 (AllStar Link 3) on Debian/Ubuntu Linux
- Root / sudo access for installation
- `curl` (pre-installed on most ASL3 systems)

---

## Installation & Updates

Run the following command as root or with sudo on your ASL3 node for both fresh installs and updates:

```bash
bash <(curl -fsSL -H "Cache-Control: no-cache" https://raw.githubusercontent.com/N6LKA/asl3-cleanup-recordings/main/install.sh)
```

**Fresh install:** The installer will prompt you to set your node number, retention days, recording directory, and cron schedule, then create your configuration file and install the cron job automatically.

**Updating:** Re-running the same command will update the script to the latest version. Your existing configuration is always preserved — only the script files are replaced.

---

## File Locations

| File | Path |
|------|------|
| Main script | `/etc/asterisk/scripts/cleanup-recordings/cleanup-recordings.sh` |
| Configuration | `/etc/asterisk/scripts/cleanup-recordings/cleanup-recordings.conf` |
| Config example | `/etc/asterisk/scripts/cleanup-recordings/cleanup-recordings.conf.example` |

---

## Configuration

Edit the config file to customize behavior:

```bash
nano /etc/asterisk/scripts/cleanup-recordings/cleanup-recordings.conf
```

| Variable | Default | Description |
|----------|---------|-------------|
| `NODE` | `501260` | Your AllStar node number |
| `DAYS_TO_KEEP` | `14` | Number of days to retain files |
| `TARGET_DIR` | `/recordings/${NODE}` | Directory where recordings are stored |
| `CRON_SCHEDULE` | `0 3 * * 0` | When to run cleanup automatically |

### Common Recording Directory Paths

| System | Path |
|--------|------|
| ASL3 (default) | `/recordings/${NODE}` |
| ASL3 (original) | `/var/spool/asterisk/monitor/${NODE}` |
| HamVOIP | `/media/MS1/${NODE}` |

### Cron Schedule Examples

| Schedule | Meaning |
|----------|---------|
| `0 3 * * 0` | Every Sunday at 3:00 AM (default) |
| `0 3 * * *` | Every day at 3:00 AM |
| `0 3 1 * *` | First day of every month at 3:00 AM |

After editing the config, the new cron schedule takes effect on the next installer run (to update the cron job). Retention and directory changes take effect immediately on the next run.

---

## Usage

### Run manually (normal mode):
```bash
sudo /etc/asterisk/scripts/cleanup-recordings/cleanup-recordings.sh
```

### Run in test mode (no files deleted):
```bash
sudo /etc/asterisk/scripts/cleanup-recordings/cleanup-recordings.sh test
```

Test mode output example:
```
-------------------------------------------
 AllStar Recording Cleanup Utility (TEST MODE)
 Node: 501260
 Directory: /recordings/501260
 Retention: 9 days
 Files before cleanup: 142
-------------------------------------------
Files that WOULD be deleted:
/recordings/501260/20250301-142301.WAV
/recordings/501260/20250301-142301.txt
...
-------------------------------------------
Total files that would be deleted: 28
No files deleted (TEST MODE).
-------------------------------------------
```

---

## Uninstalling

To remove the script and cron job manually:

```bash
# Remove cron job
crontab -l | grep -v "cleanup-recordings" | crontab -

# Remove files
sudo rm -rf /etc/asterisk/scripts/cleanup-recordings
```

---

## License

GNU General Public License v3.0 (GPLv3) — Copyright 2026 Larry K. Aycock (N6LKA)

See [LICENSE](LICENSE) for details.
