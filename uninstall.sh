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

SERVICE_NAME="allmon3-archive"
INSTALL_DIR="/opt/allmon3-archive"
ALLMON3_WEB="/usr/share/allmon3"
NGINX_CONF="/etc/allmon3/nginx.conf"
NGINX_MARKER="# allmon3-archive: managed block"

echo ""
echo "============================================================"
echo "  ASL3 Audio Archive Uninstaller"
echo "============================================================"
echo ""

# Stop and remove service
if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    systemctl stop "$SERVICE_NAME"
    ok "Service stopped."
fi
if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    systemctl disable "$SERVICE_NAME"
fi
rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload
ok "Service removed."

# Remove API files
rm -rf "$INSTALL_DIR"
ok "API files removed."

# Remove web pages
rm -f "$ALLMON3_WEB/recordings-widget.html"
rm -f "$ALLMON3_WEB/recordings-browser.html"
ok "Web pages removed."

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
echo "  and /etc/cron.d/allmon3-cleanup-recordings manually."
echo ""
echo "  Also remove iframepost = recordings-widget.html from"
echo "  /etc/allmon3/allmon3.ini and restart Allmon3."
echo ""
echo -e "  ${GREEN}Uninstall complete.${NC}"
echo ""
