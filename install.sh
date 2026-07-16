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

# ── Step 2: Python dependencies ───────────────────────────────────────────────
info "Checking Python 3..."
command -v python3 &>/dev/null || die "python3 not found. Install it and re-run."
command -v pip3   &>/dev/null || die "pip3 not found. Install python3-pip and re-run."
ok "Python 3 found: $(python3 --version)"

info "Installing Python dependencies (fastapi, uvicorn, httpx)..."
pip3 install -q --break-system-packages fastapi "uvicorn[standard]" httpx \
    || pip3 install -q fastapi "uvicorn[standard]" httpx
ok "Python dependencies installed."

# ── Step 3: Backend API ───────────────────────────────────────────────────────
info "Deploying archive API..."
mkdir -p "$INSTALL_DIR"
fetch_repo_file "backend/archive_api.py" "$INSTALL_DIR/archive_api.py"
chmod 644 "$INSTALL_DIR/archive_api.py"
ok "API deployed to $INSTALL_DIR/archive_api.py"

# Patch RECORDINGS_DIR default in service if needed (uses env var, conf is in service)
RECORDINGS_DIR="/recordings/${NODE}"
SVC_SRC="$REPO_TMP_DIR/backend/allmon3-archive.service"
sed "s|RECORDINGS_DIR=/recordings/501260|RECORDINGS_DIR=${RECORDINGS_DIR}|" \
    "$SVC_SRC" > "/etc/systemd/system/${SERVICE_NAME}.service"
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

# ── Step 5: nginx location block ─────────────────────────────────────────────
info "Configuring nginx..."
[[ -f "$NGINX_CONF" ]] || die "nginx config not found: $NGINX_CONF"

if grep -q "$NGINX_MARKER" "$NGINX_CONF"; then
    ok "nginx location block already present — skipping."
else
    BACKUP="${NGINX_CONF}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$NGINX_CONF" "$BACKUP"
    ok "nginx.conf backed up to $BACKUP"

    # Insert location block before the last closing brace using Python
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
last_brace = content.rfind('}')
if last_brace == -1:
    print("ERROR: no closing brace found in nginx.conf", file=sys.stderr)
    sys.exit(1)
new_content = content[:last_brace] + block + content[last_brace:]
open(path, 'w').write(new_content)
PYEOF

    nginx -t 2>/dev/null || die "nginx config test failed after edit. Restoring backup..." \
        && cp "$BACKUP" "$NGINX_CONF"
    nginx -s reload
    ok "nginx updated and reloaded."
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
