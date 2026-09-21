#!/bin/sh
# BUILD-ONLY test script -- not part of the shipped kit. Restores the image the kit
# captured onto a second, blank disk, so we can prove the image is actually usable.
# Resolves the destination by disk serial for the same reason the capture does: device
# ordering is not stable, and a restore that guesses wrong destroys the wrong disk.
DEST_SERIAL=TOASTRST01
MEDIUM=""
for m in /run/live/medium /lib/live/mount/medium; do
    [ -d "$m/TOAST" ] && { MEDIUM="$m"; break; }
done
LOG="$MEDIUM/TOAST/logs/restore-test.log"
IMAGE=$(head -2 "$MEDIUM/TOAST/config/capture.done" | tail -1)

DEST=""
for link in /dev/disk/by-id/*; do
    [ -e "$link" ] || continue
    case "$link" in *-part*) continue ;; esac
    case "$link" in *"$DEST_SERIAL"*) DEST=$(basename "$(readlink -f "$link")") ;; esac
done

mount -o remount,rw "$MEDIUM" 2>/dev/null
mkdir -p /home/partimag 2>/dev/null
mount --bind "$MEDIUM/home/partimag" /home/partimag

{
  echo "=== restore test $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo "image=$IMAGE dest=/dev/$DEST"
} >> "$LOG" 2>/dev/null

[ -n "$DEST" ] || { echo "no destination disk with serial $DEST_SERIAL"; sleep 10; poweroff; }

# No -scr: let it check the image is restorable, same as the capture side does.
/usr/sbin/ocs-sr -b -r -j2 -icds restoredisk "$IMAGE" "$DEST"
RC=$?
mount -o remount,rw "$MEDIUM" 2>/dev/null
echo "ocs-sr restore exit=$RC" >> "$LOG" 2>/dev/null
sync
echo "RESTORE TEST exit=$RC"
sleep 15
poweroff
