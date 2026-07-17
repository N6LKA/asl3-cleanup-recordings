#!/usr/bin/env bash
# =============================================================================
#  ASL3-Audio-Archive install.sh
#  Installs the Allmon3 audio archive browser and cleanup daemon.
#  Must be run as root or with sudo.
# =============================================================================

set -euo pipefail

REPO_NAME="ASL3-Audio-Archive"
GITHUB_ORG="N6LKA"
BRANCH="main"

INSTALL_DIR="/opt/allmon3-archive"
ALLMON3_WEB="/usr/share/allmon3"
CLEANUP_SCRIPT_DIR="/etc/asterisk/scripts/cleanup-recordings"
API_SERVICE_NAME="allmon3-archive"
CLEANUP_SERVICE_NAME="allmon3-cleanup"
NGINX_CONF="/etc/allmon3/nginx.conf"
NGINX_MARKER="# allmon3-archive: managed block"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --branch) BRANCH="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERR ]${NC}  $*" >&2; exit 1; }

REPO_TMP_DIR=$(mktemp -d)
trap 'rm -rf "$REPO_TMP_DIR"' EXIT

fetch_repo_file() {
    local src="$REPO_TMP_DIR/$1"
    [[ -f "$src" ]] || die "Repo file not found: $1"
    cp "$src" "$2"
}

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  ASL3 Audio Archive Installer"
echo "  Branch: $BRANCH"
echo "============================================================"
echo ""

[[ "$BRANCH" != "main" ]] && warn "Installing from branch: $BRANCH (not main)"
[[ "$EUID" -ne 0 ]] && die "This script must be run as root (sudo)."

# ── Download repo tarball ─────────────────────────────────────────────────────
TARBALL_URL="https://github.com/${GITHUB_ORG}/${REPO_NAME}/archive/refs/heads/${BRANCH}.tar.gz"
info "Downloading repo from $TARBALL_URL"
curl -fsSL "$TARBALL_URL" -o "$REPO_TMP_DIR/repo.tar.gz" \
    || die "Failed to download repo tarball."
tar -xzf "$REPO_TMP_DIR/repo.tar.gz" -C "$REPO_TMP_DIR" --strip-components=1
ok "Repo downloaded and extracted."

# ── Detect node number ────────────────────────────────────────────────────────
NODE=""
EXISTING_CONF="$CLEANUP_SCRIPT_DIR/cleanup-recordings.conf"
if [[ -f "$EXISTING_CONF" ]]; then
    NODE=$(grep -E "^NODE=" "$EXISTING_CONF" | head -1 | cut -d'"' -f2)
    info "Detected existing node number from cleanup config: $NODE"
fi
if [[ -z "$NODE" ]]; then
    read -rp "Enter your AllStar node number: " NODE
    [[ -z "$NODE" ]] && die "Node number is required."
fi

# ── Step 1: Cleanup script ────────────────────────────────────────────────────
info "Installing cleanup script..."
mkdir -p "$CLEANUP_SCRIPT_DIR"
fetch_repo_file "cleanup/cleanup-recordings.sh"          "$CLEANUP_SCRIPT_DIR/cleanup-recordings.sh"
fetch_repo_file "cleanup/cleanup-recordings.conf.example" "$CLEANUP_SCRIPT_DIR/cleanup-recordings.conf.example"
chmod +x "$CLEANUP_SCRIPT_DIR/cleanup-recordings.sh"

CONF_FILE="$CLEANUP_SCRIPT_DIR/cleanup-recordings.conf"

# ── Migrate any existing cron schedule ───────────────────────────────────────
SCHEDULE_FREQUENCY="weekly"
SCHEDULE_DOW="0"
SCHEDULE_HOUR="3"

# Check root's crontab for an existing entry and extract its schedule
CRON_LINE=$(crontab -u root -l 2>/dev/null | grep -v "^#" | grep "cleanup-recordings" | head -1 || true)
if [[ -n "$CRON_LINE" ]]; then
    _HOUR=$(echo "$CRON_LINE" | awk '{print $2}')
    _DOW=$(echo  "$CRON_LINE" | awk '{print $5}')
    _DOM=$(echo  "$CRON_LINE" | awk '{print $3}')
    [[ "$_HOUR" =~ ^[0-9]+$ ]] && SCHEDULE_HOUR="$_HOUR"
    if [[ "$_DOW" != "*" && "$_DOW" =~ ^[0-9]+$ ]]; then
        SCHEDULE_FREQUENCY="weekly"; SCHEDULE_DOW="$_DOW"
    elif [[ "$_DOM" != "*" ]]; then
        SCHEDULE_FREQUENCY="monthly"
    else
        SCHEDULE_FREQUENCY="daily"
    fi
    # Remove the old cron entry
    ( crontab -u root -l 2>/dev/null | grep -v "cleanup-recordings" ) \
        | crontab -u root - 2>/dev/null || true
    ok "Migrated cron schedule ($SCHEDULE_FREQUENCY, hour=$SCHEDULE_HOUR) and removed from root crontab."
fi

# Also check CRON_SCHEDULE field in existing conf (earlier format)
if [[ -f "$CONF_FILE" ]]; then
    OLD_SCHED=$(grep -E "^CRON_SCHEDULE=" "$CONF_FILE" | head -1 | sed 's/CRON_SCHEDULE=//;s/"//g' || true)
    if [[ -n "$OLD_SCHED" ]]; then
        _H=$(echo "$OLD_SCHED" | awk '{print $2}')
        _D=$(echo "$OLD_SCHED" | awk '{print $5}')
        _M=$(echo "$OLD_SCHED" | awk '{print $3}')
        [[ "$_H" =~ ^[0-9]+$ ]] && SCHEDULE_HOUR="$_H"
        if [[ "$_D" != "*" && "$_D" =~ ^[0-9]+$ ]]; then
            SCHEDULE_FREQUENCY="weekly"; SCHEDULE_DOW="$_D"
        elif [[ "$_M" != "*" ]]; then
            SCHEDULE_FREQUENCY="monthly"
        else
            SCHEDULE_FREQUENCY="daily"
        fi
        info "Migrated CRON_SCHEDULE from existing conf to new schedule fields."
    fi
fi

# Remove old /etc/cron.d file if present from a previous install
OLD_CRON_D="/etc/cron.d/allmon3-cleanup-recordings"
if [[ -f "$OLD_CRON_D" ]]; then
    rm -f "$OLD_CRON_D"
    ok "Removed $OLD_CRON_D (schedule now managed by daemon service)."
fi

# ── Write / update conf file ──────────────────────────────────────────────────
if [[ ! -f "$CONF_FILE" ]]; then
    cp "$CLEANUP_SCRIPT_DIR/cleanup-recordings.conf.example" "$CONF_FILE"
    sed -i "s|^NODE=.*|NODE=\"${NODE}\"|"                 "$CONF_FILE"
    sed -i "s|^\(TARGET_DIR=\).*|\1\"/recordings/${NODE}\"|" "$CONF_FILE"
    ok "Created cleanup config: $CONF_FILE"
else
    ok "Existing cleanup config retained: $CONF_FILE"
fi

# Ensure new schedule fields exist and are set correctly
# (adds them if absent; updates value if present)
set_conf_field() {
    local file="$1" key="$2" val="$3"
    if grep -q "^${key}=" "$file"; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$file"
    else
        # Remove old CRON_SCHEDULE if still present, add new fields
        sed -i "/^CRON_SCHEDULE=/d" "$file"
        echo "${key}=${val}" >> "$file"
    fi
}
set_conf_field "$CONF_FILE" "SCHEDULE_FREQUENCY" "$SCHEDULE_FREQUENCY"
set_conf_field "$CONF_FILE" "SCHEDULE_DOW"       "$SCHEDULE_DOW"
set_conf_field "$CONF_FILE" "SCHEDULE_HOUR"      "$SCHEDULE_HOUR"
# Remove legacy CRON_SCHEDULE field if present
sed -i "/^CRON_SCHEDULE=/d" "$CONF_FILE"

# Make conf group-writable by www-data so the archive API can save settings
chown root:www-data "$CONF_FILE"
chmod 664 "$CONF_FILE"
ok "Config permissions set (group-writable by www-data)."

# ── Step 2: System dependencies ───────────────────────────────────────────────
info "Checking system dependencies..."
command -v python3 &>/dev/null || die "python3 not found. Install it and re-run."
ok "Python 3 found: $(python3 --version)"
command -v sox &>/dev/null || {
    info "Installing sox (required for audio format conversion)..."
    apt-get install -y -qq sox || die "Could not install sox. Run: apt install sox"
}
ok "sox found: $(sox --version 2>&1 | head -1)"

# ── Step 3: Python virtual environment ───────────────────────────────────────
info "Setting up Python virtual environment..."
apt-get install -y -qq python3-venv 2>/dev/null \
    || apt-get install -y -qq "python$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')-venv" \
    || die "Could not install python3-venv. Run: apt install python3-venv"
mkdir -p "$INSTALL_DIR"
python3 -m venv "$INSTALL_DIR/venv"
ok "Virtual environment ready at $INSTALL_DIR/venv"

info "Installing Python dependencies..."
"$INSTALL_DIR/venv/bin/pip" install -q fastapi "uvicorn[standard]" httpx
ok "Python dependencies installed."

VENV_PYTHON="$INSTALL_DIR/venv/bin/python"

# ── Step 4: Archive API service ───────────────────────────────────────────────
info "Deploying archive API..."
fetch_repo_file "backend/archive_api.py" "$INSTALL_DIR/archive_api.py"
chmod 644 "$INSTALL_DIR/archive_api.py"

RECORDINGS_DIR="/recordings/${NODE}"
cat > "/etc/systemd/system/${API_SERVICE_NAME}.service" <<EOF
[Unit]
Description=Allmon3 Audio Archive API
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=${INSTALL_DIR}
ExecStart=${VENV_PYTHON} -m uvicorn archive_api:app --host 127.0.0.1 --port 8765
Restart=always
RestartSec=5
Environment=RECORDINGS_DIR=${RECORDINGS_DIR}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$API_SERVICE_NAME" &>/dev/null
systemctl restart "$API_SERVICE_NAME"
ok "Archive API service started."

# ── Step 5: Cleanup daemon service ────────────────────────────────────────────
info "Deploying cleanup daemon..."
fetch_repo_file "backend/cleanup_daemon.py" "$INSTALL_DIR/cleanup_daemon.py"
chmod 644 "$INSTALL_DIR/cleanup_daemon.py"

cat > "/etc/systemd/system/${CLEANUP_SERVICE_NAME}.service" <<EOF
[Unit]
Description=Allmon3 Archive Cleanup Daemon
After=network.target

[Service]
Type=simple
ExecStart=${VENV_PYTHON} ${INSTALL_DIR}/cleanup_daemon.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$CLEANUP_SERVICE_NAME" &>/dev/null
systemctl restart "$CLEANUP_SERVICE_NAME"
ok "Cleanup daemon started (schedule: $SCHEDULE_FREQUENCY at ${SCHEDULE_HOUR}:00)."

# ── Step 6: Web pages ─────────────────────────────────────────────────────────
info "Deploying web pages to $ALLMON3_WEB..."
[[ -d "$ALLMON3_WEB" ]] || die "$ALLMON3_WEB not found — is Allmon3 installed?"
fetch_repo_file "web/recordings-widget.html"  "$ALLMON3_WEB/recordings-widget.html"
fetch_repo_file "web/recordings-browser.html" "$ALLMON3_WEB/recordings-browser.html"
ok "Web pages deployed."

# ── Step 7: Web server proxy configuration ────────────────────────────────────
info "Configuring web server proxy..."

APACHE_CONF_DIR="/etc/apache2/conf-available"
APACHE_CONF="$APACHE_CONF_DIR/allmon3-archive.conf"
APACHE_MARKER="# allmon3-archive: managed"

if systemctl is-active --quiet apache2 2>/dev/null; then
    info "Apache detected."
    a2enmod proxy proxy_http &>/dev/null || true
    if [[ -f "$APACHE_CONF" ]] && grep -q "$APACHE_MARKER" "$APACHE_CONF"; then
        ok "Apache proxy config already present — skipping."
    else
        cat > "$APACHE_CONF" <<APEOF
${APACHE_MARKER}
ProxyPass /allmon3/archive/ "http://127.0.0.1:8765/archive/"
APEOF
        a2enconf allmon3-archive &>/dev/null
        ok "Apache proxy config installed: $APACHE_CONF"
    fi
    apachectl configtest 2>/dev/null || die "Apache config test failed."
    systemctl reload apache2
    ok "Apache reloaded."

elif systemctl is-active --quiet nginx 2>/dev/null || pgrep -x nginx &>/dev/null; then
    info "nginx detected."
    [[ -f "$NGINX_CONF" ]] || die "nginx config not found: $NGINX_CONF"
    if grep -q "$NGINX_MARKER" "$NGINX_CONF"; then
        ok "nginx location block already present — skipping."
    else
        BACKUP="${NGINX_CONF}.bak.$(date +%Y%m%d-%H%M%S)"
        cp "$NGINX_CONF" "$BACKUP"
        ok "nginx.conf backed up to $BACKUP"
        python3 - "$NGINX_CONF" "$NGINX_MARKER" <<'PYEOF'
import sys
path, marker = sys.argv[1], sys.argv[2]
block = f"""
{marker}
location /allmon3/archive/ {{
    proxy_pass http://127.0.0.1:8765/archive/;
    proxy_set_header Host $http_host;
}}
"""
content = open(path).read()
open(path, 'w').write(content.rstrip() + '\n' + block)
PYEOF
        NGINX_BIN=$(command -v nginx || echo /usr/sbin/nginx)
        "$NGINX_BIN" -t 2>/dev/null || { cp "$BACKUP" "$NGINX_CONF"; die "nginx config test failed — backup restored."; }
        "$NGINX_BIN" -s reload
        ok "nginx updated and reloaded."
    fi
else
    die "Could not detect a running web server (apache2 or nginx). Is Allmon3 installed?"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo -e "  ${GREEN}Installation complete!${NC}"
echo "============================================================"
echo ""
echo "  One manual step required:"
echo ""
echo "  Add this to /etc/allmon3/allmon3.ini under [${NODE}]:"
echo ""
echo "      iframepost = recordings-widget.html"
echo ""
echo "  Then restart Allmon3:"
echo ""
echo "      sudo systemctl restart allmon3"
echo ""
echo "  The archive browser is available at:"
echo "      http://<your-node>/allmon3/recordings-browser.html"
echo ""
echo "  Cleanup schedule: $SCHEDULE_FREQUENCY at ${SCHEDULE_HOUR}:00"
echo "  Adjust anytime via the Settings panel in the archive browser."
echo ""
