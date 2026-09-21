#!/bin/sh
# TOAST Image Capture Kit - put the disk back to full size after a capture that
# was interrupted.
#
# Only one situation needs this: power was lost between the shrink and the
# expand, so Windows is sitting in a filesystem smaller than its partition. The
# unit still boots and no data is lost; it just looks alarming and wastes the
# rest of the disk. The fix is only the expand.
set -u

MEDIUM=""
for m in ${TOAST_MEDIUM:-} /run/live/medium /lib/live/mount/medium; do
    [ -n "$m" ] && [ -d "$m/TOAST" ] && { MEDIUM="$m"; break; }
done
[ -n "$MEDIUM" ] || MEDIUM=${TOAST_MEDIUM:-/run/live/medium}

# Everything shared by the kit scripts: answer parsing and toast_poweroff.
# Sourced, never duplicated -- prompts that behave differently from each other on
# one USB stick are a support call, and a pasted poweroff drifts back to a bare
# one. See ocs-common.sh.
TOAST_SCRIPTS=$(dirname "$0" 2>/dev/null)
case "$TOAST_SCRIPTS" in ''|.) TOAST_SCRIPTS="$MEDIUM/TOAST/scripts" ;; esac
[ -r "$TOAST_SCRIPTS/ocs-common.sh" ] || TOAST_SCRIPTS="$MEDIUM/TOAST/scripts"
if [ ! -r "$TOAST_SCRIPTS/ocs-common.sh" ]; then
    echo "TOAST: a file this kit needs is missing from the USB drive"
    echo "        (TOAST\\scripts\\ocs-common.sh). Contact your supplier."
    sleep 30
    systemctl -f poweroff 2>/dev/null || poweroff -f 2>/dev/null || poweroff
    exit 1
fi
. "$TOAST_SCRIPTS/ocs-common.sh"


echo ""
echo "==============================================================="
echo " TOAST: REPAIR DISK SPACE AFTER AN INTERRUPTED CAPTURE"
echo "==============================================================="
echo ""

sh "$MEDIUM/TOAST/scripts/ocs-shrink.sh" repair
RC=$?

echo ""
if [ $RC -eq 0 ]; then
    echo " The disk is back to its full size. Start Windows normally."
    echo ""
    echo " If nothing needed repairing, that is the expected result and"
    echo " means the last capture finished cleanly."
else
    echo " The repair did not finish. Contact your supplier and quote"
    echo " the log on this USB drive in TOAST\\logs\\shrink.log."
fi
echo ""
echo " Press Enter to power off."
read -r _ 2>/dev/null || true
toast_poweroff