#!/bin/sh
# TOAST Image Capture Kit - shrink, unattended save, expand back, then write the
# completion marker.
#
# ORDER MATTERS: prompt (in ocs-prerun.sh), then shrink, then capture, then
# expand. Nobody should meet a dialog after a twenty minute operation, and the
# shrink has to happen before partclone takes the bitmap or it achieves nothing.
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

LOG="$MEDIUM/TOAST/logs/capture.log"
SHRINK="$MEDIUM/TOAST/scripts/ocs-shrink.sh"

# Both files, and both non-empty. The prerun ends in "exit 0", so a failure to
# write either one would otherwise arrive here as an empty $IMAGE and ocs-sr
# would be handed a blank image name.
[ -s /tmp/toast_target ] && [ -s /tmp/toast_image ] || {
    echo "TOAST: the previous step did not say which disk to capture."
    sleep 30; toast_poweroff; }
TARGET=$(cat /tmp/toast_target)
IMAGE=$(cat /tmp/toast_image)
[ -n "$TARGET" ] && [ -n "$IMAGE" ] || {
    echo "TOAST: the target disk or image name came back empty."
    sleep 30; toast_poweroff; }

mount -o remount,rw "$MEDIUM" 2>/dev/null
{
  echo "=== TOAST capture $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo "target=/dev/$TARGET image=$IMAGE"
} >> "$LOG" 2>/dev/null

# --- the expand-back must happen on EVERY exit path -------------------------
#
# A failed capture, a cancelled capture, an ocs-sr non-zero exit, or a signal.
# Same shape as a fail-fast installer late-commands block: the step that MUST
# happen cannot sit behind a step that can abort.
#
# ocs-shrink.sh expand is idempotent (it clears its own state on success and is a
# no-op when there is no state), so calling it explicitly AND from the trap is
# safe. The explicit call is what actually runs in the normal case, because
# `poweroff` at the end of this script does not reliably let an EXIT trap finish.
EXPANDED=no
expand_back() {
    [ "$EXPANDED" = yes ] && return 0
    EXPANDED=yes
    echo ""
    echo "TOAST: restoring the Windows partition to its full size..."
    if sh "$SHRINK" expand; then
        return 0
    fi
    # This is the one failure the customer must not be left unaware of.
    echo ""
    echo "==============================================================="
    echo " IMPORTANT - THE DISK WAS NOT PUT BACK TO FULL SIZE"
    echo "==============================================================="
    echo " Windows will still start and no data has been lost, but part"
    echo " of the disk is unusable until this is repaired."
    echo ""
    echo " Boot this USB drive again and choose:"
    echo "   'TOAST: Repair disk space after an interrupted capture'"
    echo "==============================================================="
    return 1
}
trap 'expand_back' EXIT INT TERM HUP

# --- shrink -----------------------------------------------------------------
echo ""
echo "TOAST: preparing the Windows partition (step 1 of 2)."
echo "        This makes the image small enough to restore onto a smaller disk."
echo ""
if ! sh "$SHRINK" shrink "$TARGET"; then
    # ocs-shrink.sh has already printed a specific, actionable reason and has
    # changed nothing. Do not capture a filesystem we could not prepare.
    echo "TOAST: not capturing, because the disk could not be prepared."
    echo "ABORT: shrink failed, capture not attempted" >> "$LOG" 2>/dev/null
    expand_back
    sleep 30
    toast_poweroff
    exit 1
fi

# --- capture ----------------------------------------------------------------
echo ""
echo "TOAST: capturing the image (step 2 of 2)."
echo ""
# Verification (no -scs) is deliberate: a bad capture must surface while the unit
# is still in front of the customer, not after a 40-60 GB upload.
#
# -i 4096 is FAT32-safe: Clonezilla splits with `split -b 4096MB` and GNU MB is
# 10^6, so volumes are 4.096e9 bytes, under FAT32's 4 GiB per-file limit. This is
# also the value Clonezilla's own check_if_repo_fat_tune_image_vol_limit picks.
#
# -z9p is parallel zstd (`zstd -c -T0 -3`), chosen on measured numbers against a
# real customer volume on 2026-09-04, not on reputation:
#   -z1p  gzip -1  8.44 GB   (Clonezilla's --fast, the weakest setting it offers)
#   -z9p  zstd -3  7.87 GB   -6.8%, and it used 14% of ONE core
#   -z5p  xz -3    7.45 GB   -11.7%, but ~600% CPU and it throttled the whole
#                            pipeline to ~30 MB/s on a 24-thread server
# zstd is the only one of the three that is both smaller than today and free.
# ⛔ Do not "improve" this to -z5p without re-reading that note: on a 4-core
# tablet the customer waits for xz, and the gain over zstd is 0.41 GB.
/usr/sbin/ocs-sr -q2 -j2 -z9p -i 4096 -sfsck -senc savedisk "$IMAGE" "$TARGET"
RC=$?

mount -o remount,rw "$MEDIUM" 2>/dev/null
echo "ocs-sr exit=$RC" >> "$LOG" 2>/dev/null

# --- expand back, before anything else --------------------------------------
expand_back
EXRC=$?

if [ $RC -eq 0 ]; then
    date -u +%Y-%m-%dT%H:%M:%SZ > "$MEDIUM/TOAST/config/capture.done"
    echo "$IMAGE" >> "$MEDIUM/TOAST/config/capture.done"
    sync
    echo ""
    if [ $EXRC -eq 0 ]; then
        echo "  CAPTURE COMPLETE. Remove nothing. The unit will now power off."
        echo "  Turn it back on, let Windows start, and follow the upload steps."
    else
        echo "  The image was captured, but read the warning above before"
        echo "  using this computer."
    fi
else
    sync
    echo ""
    echo "  CAPTURE FAILED (code $RC). Do not upload anything."
    echo "  Contact your supplier - the log is on the USB in TOAST\\logs."
fi
sleep 20
toast_poweroff