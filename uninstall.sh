#!/usr/bin/env bash
# =============================================================================
#  ASL3-Audio-Archive uninstall.sh
#  Removes the archive browser. Does NOT remove the cleanup script or its data.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC}  $*"; }
die()  { echo -e "${RED}[ERR ]${NC}  $*" >&2; exit 1; }

[[ "$EUID" -ne 0 ]] && die "This script must be run as root (sudo)."

API_SERVICE_NAME="allmon3-archive"
CLEANUP_SERVICE_NAME="allmon3-cleanup"
INSTALL_DIR="/opt/allmon3-archive"
ALLMON3_WEB="/usr/share/allmon3"
NGINX_CONF="/etc/allmon3/nginx.conf"
NGINX_MARKER="# allmon3-archive: managed block"
APACHE_CONF="/etc/apache2/conf-available/allmon3-archive.conf"

echo ""
echo "============================================================"
echo "  ASL3 Audio Archive Uninstaller"
echo "============================================================"
echo ""

# Stop and remove archive API service
if systemctl is-active --quiet "$API_SERVICE_NAME" 2>/dev/null; then
    systemctl stop "$API_SERVICE_NAME"
fi
if systemctl is-enabled --quiet "$API_SERVICE_NAME" 2>/dev/null; then
    systemctl disable "$API_SERVICE_NAME" &>/dev/null
fi
rm -f "/etc/systemd/system/${API_SERVICE_NAME}.service"
ok "Archive API service removed."

# Stop and remove cleanup daemon service
if systemctl is-active --quiet "$CLEANUP_SERVICE_NAME" 2>/dev/null; then
    systemctl stop "$CLEANUP_SERVICE_NAME"
fi
if systemctl is-enabled --quiet "$CLEANUP_SERVICE_NAME" 2>/dev/null; then
    systemctl disable "$CLEANUP_SERVICE_NAME" &>/dev/null
fi
rm -f "/etc/systemd/system/${CLEANUP_SERVICE_NAME}.service"
ok "Cleanup daemon service removed."

systemctl daemon-reload

# Remove API and daemon files
rm -rf "$INSTALL_DIR"
ok "Backend files removed ($INSTALL_DIR)."

# Remove web pages
rm -f "$ALLMON3_WEB/recordings-widget.html"
rm -f "$ALLMON3_WEB/recordings-browser.html"
ok "Web pages removed."

# Remove Apache proxy config
if [[ -f "$APACHE_CONF" ]]; then
    a2disconf allmon3-archive &>/dev/null || true
    rm -f "$APACHE_CONF"
    apachectl configtest 2>/dev/null && systemctl reload apache2 || true
    ok "Apache proxy config removed."
fi

# Remove nginx block
if grep -q "$NGINX_MARKER" "$NGINX_CONF" 2>/dev/null; then
    BACKUP="${NGINX_CONF}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$NGINX_CONF" "$BACKUP"
    python3 - "$NGINX_CONF" "$NGINX_MARKER" <<'PYEOF'
import sys, re
path, marker = sys.argv[1], sys.argv[2]
content = open(path).read()
pattern = r'\n' + re.escape(marker) + r'.*?location /allmon3/archive/.*?\}\n'
new_content = re.sub(pattern, '\n', content, flags=re.DOTALL)
open(path, 'w').write(new_content.rstrip() + '\n')
PYEOF
    nginx -t 2>/dev/null && nginx -s reload
    ok "nginx location block removed."
fi

echo ""
echo "  Note: The cleanup script and its config were NOT removed."
echo "  To remove those, delete /etc/asterisk/scripts/cleanup-recordings/"
echo ""
echo "  Also remove iframepost = recordings-widget.html from"
echo "  /etc/allmon3/allmon3.ini and restart Allmon3:"
echo ""
echo "      sudo systemctl restart allmon3"
echo ""
echo -e "  ${GREEN}Uninstall complete.${NC}"
echo ""
