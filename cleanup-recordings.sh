#!/bin/bash
#
# ------------------------------------------------------------
#  cleanup-recordings.sh
#
#  Author: Larry K. Aycock (N6LKA)
#
#  Purpose:
#     Automatically clean old AllStar recording files from the
#     recordings directory. Supports "test mode" to preview
#     what would be deleted without removing anything.
#
#  Usage:
#     ./cleanup-recordings.sh         (normal mode)
#     ./cleanup-recordings.sh test    (test mode - no deletion)
#
# ------------------------------------------------------------

SCRIPT_DIR="/etc/asterisk/scripts/cleanup-recordings"
CONF_FILE="$SCRIPT_DIR/cleanup-recordings.conf"

# ====== LOAD CONFIG ======
if [ ! -f "$CONF_FILE" ]; then
    echo "ERROR: Config file not found: $CONF_FILE"
    echo "Run the install script or create the config file manually."
    exit 1
fi
source "$CONF_FILE"

# ====== DETECT TEST MODE ======
TEST_MODE=false
if [ "$1" == "test" ]; then
    TEST_MODE=true
fi

# ====== FILE COUNT BEFORE ======
before_count=$(find "$TARGET_DIR" -type f | wc -l)

echo "-------------------------------------------"
if [ "$TEST_MODE" = true ]; then
    echo " AllStar Recording Cleanup Utility (TEST MODE)"
else
    echo " AllStar Recording Cleanup Utility"
fi

echo " Node: $NODE"
echo " Directory: $TARGET_DIR"
echo " Retention: $DAYS_TO_KEEP days"
echo " Files before cleanup: $before_count"
echo "-------------------------------------------"

# ====== CLEANUP OR TEST LISTING ======

if [ "$TEST_MODE" = true ]; then
    echo "Files that WOULD be deleted:"
    would_delete=$(find "$TARGET_DIR" -type f \( -name "*.WAV" -o -name "*.txt" \) -mtime +$DAYS_TO_KEEP)

    if [ -z "$would_delete" ]; then
        echo "(No files would be deleted.)"
    else
        echo "$would_delete"
    fi

    delete_count=$(echo "$would_delete" | grep -c .)

    echo "-------------------------------------------"
    echo "Total files that would be deleted: $delete_count"
    echo "No files deleted (TEST MODE)."
    echo "-------------------------------------------"

else
    # Normal deletion mode
    find "$TARGET_DIR" -type f \( -name "*.WAV" -o -name "*.txt" \) -mtime +$DAYS_TO_KEEP -delete

    after_count=$(find "$TARGET_DIR" -type f | wc -l)
    deleted=$((before_count - after_count))

    echo "Files deleted: $deleted"
    echo "Files after cleanup: $after_count"
    echo "Cleanup completed."
    echo "-------------------------------------------"
fi
