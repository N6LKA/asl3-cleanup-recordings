#!/usr/bin/env bash
# =============================================================================
#  ASL3-Audio-Archive install.sh
#  Installs the Allmon3 audio archive browser and cleanup scheduler.
# =============================================================================

set -euo pipefail

REPO_NAME="ASL3-Audio-Archive"
GITHUB_ORG="N6LKA"
BRANCH="main"

INSTALL_DIR="/opt/allmon3-archive"
ALLMON3_WEB="/usr/share/allmon3"
CLEANUP_SCRIPT_DIR="/etc/asterisk/scripts/cleanup-recordings"
SERVICE_NAME="allmon3-archive"
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
    # Usage: fetch_repo_file <src-path-in-repo> <dest>
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
fetch_repo_file "cleanup/cleanup-recordings.sh" "$CLEANUP_SCRIPT_DIR/cleanup-recordings.sh"
chmod +x "$CLEANUP_SCRIPT_DIR/cleanup-recordings.sh"

CONF_FILE="$CLEANUP_SCRIPT_DIR/cleanup-recordings.conf"
EXAMPLE_FILE="$CLEANUP_SCRIPT_DIR/cleanup-recordings.conf.example"
fetch_repo_file "cleanup/cleanup-recordings.conf.example" "$EXAMPLE_FILE"

if [[ ! -f "$CONF_FILE" ]]; then
    cp "$EXAMPLE_FILE" "$CONF_FILE"
    sed -i "s|^NODE=.*|NODE=\"${NODE}\"|" "$CONF_FILE"
    sed -i "s|^\(TARGET_DIR=\).*|\1\"/recordings/${NODE}\"|" "$CONF_FILE"
    ok "Created cleanup config: $CONF_FILE"
else
    ok "Existing cleanup config retained: $CONF_FILE"
fi

# Set up cron job for cleanup
CRON_CMD="0 3 * * 0 root $CLEANUP_SCRIPT_DIR/cleanup-recordings.sh >> /var/log/cleanup-recordings.log 2>&1"
CRON_FILE="/etc/cron.d/allmon3-cleanup-recordings"
if [[ ! -f "$CRON_FILE" ]] || ! grep -qF "$CLEANUP_SCRIPT_DIR/cleanup-recordings.sh" "$CRON_FILE"; then
    echo "$CRON_CMD" > "$CRON_FILE"
    chmod 644 "$CRON_FILE"
    ok "Cron job installed: $CRON_FILE"
else
    ok "Cron job already present."
fi

# ── Step 2: Python virtual environment + dependencies ────────────────────────
info "Checking system dependencies..."
command -v python3 &>/dev/null || die "python3 not found. Install it and re-run."
ok "Python 3 found: $(python3 --version)"
command -v sox &>/dev/null || {
    info "Installing sox (required for audio format conversion)..."
    apt-get install -y -qq sox || die "Could not install sox. Run: apt install sox"
}
ok "sox found: $(sox --version 2>&1 | head -1)"

info "Setting up Python virtual environment..."
apt-get install -y -qq python3-venv 2>/dev/null \
    || apt-get install -y -qq "python$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')-venv" \
    || die "Could not install python3-venv. Run: apt install python3-venv"
mkdir -p "$INSTALL_DIR"
python3 -m venv "$INSTALL_DIR/venv"
ok "Virtual environment created at $INSTALL_DIR/venv"

info "Installing Python dependencies (fastapi, uvicorn, httpx)..."
"$INSTALL_DIR/venv/bin/pip" install -q fastapi "uvicorn[standard]" httpx
ok "Python dependencies installed."

# ── Step 3: Backend API ───────────────────────────────────────────────────────
info "Deploying archive API..."
fetch_repo_file "backend/archive_api.py" "$INSTALL_DIR/archive_api.py"
chmod 644 "$INSTALL_DIR/archive_api.py"
ok "API deployed to $INSTALL_DIR/archive_api.py"

# Generate service file using the venv's uvicorn
RECORDINGS_DIR="/recordings/${NODE}"
VENV_PYTHON="$INSTALL_DIR/venv/bin/python"
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
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
ok "Systemd service installed."

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" &>/dev/null
systemctl restart "$SERVICE_NAME"
ok "Service $SERVICE_NAME started."

# ── Step 4: Web pages ─────────────────────────────────────────────────────────
info "Deploying web pages to $ALLMON3_WEB..."
[[ -d "$ALLMON3_WEB" ]] || die "$ALLMON3_WEB not found — is Allmon3 installed?"
fetch_repo_file "web/recordings-widget.html"  "$ALLMON3_WEB/recordings-widget.html"
fetch_repo_file "web/recordings-browser.html" "$ALLMON3_WEB/recordings-browser.html"
ok "Web pages deployed."

# ── Step 5: Web server proxy configuration ────────────────────────────────────
info "Configuring web server proxy..."

APACHE_CONF_DIR="/etc/apache2/conf-available"
APACHE_CONF="$APACHE_CONF_DIR/allmon3-archive.conf"
APACHE_MARKER="# allmon3-archive: managed"

if systemctl is-active --quiet apache2 2>/dev/null; then
    # ── Apache ────────────────────────────────────────────────────────────────
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

elif systemctl is-active --quiet nginx 2>/dev/null \
     || pgrep -x nginx &>/dev/null; then
    # ── nginx ─────────────────────────────────────────────────────────────────
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
echo "  The archive browser will be available at:"
echo "      http://<your-node>/allmon3/recordings-browser.html"
echo ""
