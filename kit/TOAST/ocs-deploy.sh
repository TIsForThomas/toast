#!/bin/sh
# TOAST Image Capture Kit - deploy an image from the USB onto this unit.
#
# ⛔ THIS IS THE ONE PART OF THE KIT THAT DESTROYS A DISK. Capture is read-only
# apart from the resize; this overwrites everything. So nothing happens without
# the operator typing the target disk's own serial number back.
#
# The pre-flight size check is the point of this script. Clonezilla will not
# refuse a too-small target on a GPT disk: ocs-expand-gpt-pt sets
# chk_tgt_disk_size_bf_mk_pt and then never tests it, so -k1 happily builds a
# smaller partition table and lets the restore die inside partclone twenty
# minutes later. We check first, using the image's own partclone header.
set -u

MEDIUM=""
for m in ${TOAST_MEDIUM:-} /run/live/medium /lib/live/mount/medium; do
    [ -n "$m" ] && [ -d "$m/TOAST" ] && { MEDIUM="$m"; break; }
done
[ -n "$MEDIUM" ] || MEDIUM=${TOAST_MEDIUM:-/run/live/medium}


REPO="$MEDIUM/home/partimag"
LOG="$MEDIUM/TOAST/logs/deploy.log"
SECTOR=512

log() {
    mount -o remount,rw "$MEDIUM" 2>/dev/null
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$LOG" 2>/dev/null
    echo "TOAST: $*"
}

bail() {
    echo ""
    echo "==============================================================="
    echo " TOAST DEPLOY - STOPPED"
    echo "==============================================================="
    echo " $1"
    echo ""
    echo " NOTHING has been written to this computer's disk."
    echo "==============================================================="
    echo ""
    log "STOP: $1"
    echo " Press Enter to power off."
    read -r _ 2>/dev/null || true
    toast_poweroff
    exit 1
}

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

human() { awk -v b="$1" 'BEGIN{ if (b>=1e12) printf "%.2f TB", b/1e12; else if (b>=1e9) printf "%.2f GB", b/1e9; else printf "%.1f MB", b/1e6 }'; }

# --- 1. pick an image --------------------------------------------------------
[ -d "$REPO" ] || bail "No image folder found on the USB drive."

set -- 
n=0
for d in "$REPO"/*/; do
    [ -d "$d" ] || continue
    # A Clonezilla image directory always carries a 'parts' file. Anything else
    # in here is not an image and must not be offered.
    [ -f "${d}parts" ] || continue
    n=$((n + 1))
    set -- "$@" "${d%/}"
done
[ "$n" -gt 0 ] || bail "There are no images on this USB drive to deploy. An image folder must sit directly in home\\partimag."

echo ""
echo "==============================================================="
echo " TOAST: DEPLOY AN IMAGE TO THIS UNIT"
echo "==============================================================="
echo " Images available on this USB drive:"
echo ""
i=0
for d in "$@"; do
    i=$((i + 1))
    sz=$(du -sb "$d" 2>/dev/null | cut -f1)
    when=$(date -r "$d/parts" '+%Y-%m-%d' 2>/dev/null || echo '?')
    printf '   %d) %-46s %10s  %s\n' "$i" "$(basename "$d")" "$(human "${sz:-0}")" "$when"
done
echo ""

if [ "$n" -eq 1 ]; then
    IMGDIR="$1"
    echo " Only one image is present, so that is the one that will be used."
else
    # Three tries, and 'stop' gets out without having to name an image.
    pick=$(ask_number "$n" "$(printf ' Type the number of the image to deploy (1-%d), or stop: ' "$n")")
    case $? in
        2) bail "Stopped before choosing an image." ;;
        0) : ;;
        *) bail "No image was chosen." ;;
    esac
    i=0
    for d in "$@"; do
        i=$((i + 1))
        [ "$i" = "$pick" ] && IMGDIR="$d"
    done
fi
IMGNAME=$(basename "$IMGDIR")
log "image chosen: $IMGNAME"

SRCDISK=$(cat "$IMGDIR/disk" 2>/dev/null | tr -d ' \r\n')
PTSF="$IMGDIR/${SRCDISK}-pt.sf"
[ -n "$SRCDISK" ] || bail "The image '$IMGNAME' does not record which disk it came from."
[ -r "$PTSF" ]    || bail "The image '$IMGNAME' has no partition table file (${SRCDISK}-pt.sf). It may be incomplete."

# --- 2. work out what the image needs ---------------------------------------
#
# The arithmetic lives in ocs-preflight.sh, deliberately, so that the calculation
# deciding whether a customer's disk gets overwritten is testable on its own
# against a real image directory, instead of only being reachable through this
# menu. Do not reimplement it here.
PF=$(sh "$MEDIUM/TOAST/scripts/ocs-preflight.sh" "$IMGDIR" 2>&1)
case "$PF" in
    *ERROR=*) bail "$(echo "$PF" | sed -n 's/^ERROR=//p' | head -1)" ;;
esac

getpf() { echo "$PF" | sed -n "s/^$1=//p" | head -1; }
need_fs_bytes=$(getpf WINDOWS_FS_BYTES)
need_used_bytes=$(getpf WINDOWS_USED_BYTES)
FIXED_BYTES=$(getpf FIXED_BYTES)
REQUIRED_BYTES=$(getpf REQUIRED_BYTES)

[ -n "$need_fs_bytes" ] && [ -n "$REQUIRED_BYTES" ] \
    || bail "Could not read the image headers for '$IMGNAME'. The image may be damaged or incomplete."
log "$IMGNAME needs $(human "$REQUIRED_BYTES") ($(human "$need_fs_bytes") filesystem as captured, $(human "${need_used_bytes:-0}") actually in use)"

# --- 3. pick and confirm the target disk ------------------------------------
MEDIUM_DEV=$(awk -v m="$MEDIUM" '$2==m {print $1}' /proc/mounts | head -1)
MEDIUM_DISK=""
[ -n "$MEDIUM_DEV" ] && MEDIUM_DISK=$(lsblk -no PKNAME "$MEDIUM_DEV" 2>/dev/null | head -1)

echo ""
# ⛔ PICKED BY NUMBER, described in words, NOT by device name. "Type sda" means
# nothing to most people who will ever run this, whichever kind of image is being
# deployed, and it invites typing the wrong three letters. So: a numbered list
# with the size, the model, the serial and what is on the disk right now. The
# serial confirmation further down is still the gate that prevents a mistake.
#
# The description is OS-agnostic on purpose: this entry deploys Linux images as
# well as Windows ones, so it names whatever it finds rather than only looking
# for Windows.
echo " Disks found inside this computer:"
echo ""
mkdir -p /tmp/toast_dprobe 2>/dev/null
cands=""
n=0
for dpath in /sys/block/*; do
    dev=$(basename "$dpath")
    case "$dev" in loop*|ram*|sr*|zram*|dm-*|md*|fd*) continue ;; esac
    [ -b "/dev/$dev" ] || continue
    [ "$dev" = "$MEDIUM_DISK" ] && continue          # never the USB we booted from
    case "$(readlink -f "$dpath")" in *usb*) continue ;; esac   # nor any other USB

    sz=$(blockdev --getsize64 "/dev/$dev" 2>/dev/null || echo 0)
    model=$(lsblk -dno MODEL "/dev/$dev" 2>/dev/null | sed 's/[[:space:]]*$//')
    serial=$(lsblk -dno SERIAL "/dev/$dev" 2>/dev/null | tr -d ' ')

    # Say what is on it, so the right disk is obvious without reading device names.
    nparts=$(lsblk -ln -o NAME "/dev/$dev" 2>/dev/null | sed 1d | wc -l | tr -d ' ')
    if [ "${nparts:-0}" -eq 0 ]; then
        what="Empty, nothing on it"
    else
        what="Has $nparts partition(s), no operating system recognised"
        for pp in $(lsblk -ln -o NAME,FSTYPE "/dev/$dev" 2>/dev/null | sed 1d | awk 'NF>1{print $1" "$2}' | tr ' ' ':'); do
            pn=${pp%%:*}; pfs=${pp##*:}
            case "$pfs" in
                ntfs)
                    mount -t ntfs-3g -o ro "/dev/$pn" /tmp/toast_dprobe 2>/dev/null || continue
                    [ -d /tmp/toast_dprobe/Windows/System32 ] && \
                        what="HAS WINDOWS ON IT NOW - this would be erased"
                    ;;
                ext2|ext3|ext4|xfs|btrfs)
                    mount -o ro "/dev/$pn" /tmp/toast_dprobe 2>/dev/null || continue
                    if [ -r /tmp/toast_dprobe/etc/os-release ]; then
                        nm=$(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}/\1/p' /tmp/toast_dprobe/etc/os-release 2>/dev/null | head -1)
                        what="HAS ${nm:-LINUX} ON IT NOW - this would be erased"
                    elif [ -d /tmp/toast_dprobe/etc ]; then
                        what="HAS LINUX ON IT NOW - this would be erased"
                    fi
                    ;;
                *) continue ;;
            esac
            umount /tmp/toast_dprobe 2>/dev/null
            case "$what" in "HAS "*) break ;; esac
        done
    fi

    n=$((n + 1))
    cands="$cands $dev"
    printf '   %d)  %-10s  %s\n' "$n" "$(human "$sz")" "${model:-Unknown disk}"
    printf '       Serial: %s\n' "${serial:-not reported by this disk}"
    printf '       %s\n' "$what"
    echo ""
done
[ "$n" -gt 0 ] || bail "No disk was found inside this computer to write to."

echo ""
echo " The image needs at least $(human "$REQUIRED_BYTES") of disk:"
echo "   $(human "$need_fs_bytes") for Windows itself, as it was captured"
echo "   $(human "$FIXED_BYTES") for the boot, reserved and recovery partitions"
echo ""
# Three tries, because a mistyped digit used to power the unit off and mean
# rebooting it to try again. 'stop' is a first-class answer here: choosing no
# disk at all has to be possible at the prompt that picks what gets erased.
pick=$(ask_number "$n" "$(printf ' Type the number of the disk to write to (1-%d), or stop: ' "$n")")
case $? in
    2) bail "Stopped before choosing a disk. Nothing was written." ;;
    0) : ;;
    *) bail "No disk was chosen. Nothing was written." ;;
esac
tgt=""
i=0
for c in $cands; do
    i=$((i + 1))
    [ "$i" -eq "$pick" ] 2>/dev/null && tgt="$c"
done
[ -n "$tgt" ] || bail "Could not work out which disk number $pick refers to."

TGT_BYTES=$(blockdev --getsize64 "/dev/$tgt")
TGT_SERIAL=$(lsblk -dno SERIAL "/dev/$tgt" 2>/dev/null | tr -d ' ')
TGT_MODEL=$(lsblk -dno MODEL "/dev/$tgt" 2>/dev/null | sed 's/[[:space:]]*$//')

# --- 4. the pre-flight check ------------------------------------------------
if [ "$TGT_BYTES" -lt "$REQUIRED_BYTES" ]; then
    echo ""
    echo "==============================================================="
    echo " THIS IMAGE WILL NOT FIT ON THIS DISK"
    echo "==============================================================="
    echo " Image '$IMGNAME' needs : $(human "$REQUIRED_BYTES")"
    echo " /dev/$tgt provides    : $(human "$TGT_BYTES")"
    echo " Short by              : $(human $((REQUIRED_BYTES - TGT_BYTES)))"
    echo ""
    echo " The Windows filesystem inside this image was captured at"
    echo " $(human "$need_fs_bytes"). partclone writes blocks at their original"
    echo " offsets, so it cannot be made to fit a smaller space here,"
    echo " however little data it holds."
    echo ""
    echo " The image has to be re-captured from a shrunk filesystem."
    echo " The TOAST capture entry on this USB does that automatically."
    echo "==============================================================="
    log "PREFLIGHT REFUSED: need $REQUIRED_BYTES, target $TGT_BYTES"
    echo ""
    echo " Press Enter to power off."
    read -r _ 2>/dev/null || true
    toast_poweroff
    exit 1
fi
log "preflight OK: need $REQUIRED_BYTES, target /dev/$tgt has $TGT_BYTES"

# --- 5. final confirmation --------------------------------------------------
echo ""
echo "==============================================================="
echo " EVERYTHING ON THIS DISK WILL BE ERASED"
echo "==============================================================="
echo " Disk   : /dev/$tgt"
echo " Model  : ${TGT_MODEL:-unknown}"
echo " Serial : ${TGT_SERIAL:-unknown}"
echo " Size   : $(human "$TGT_BYTES")"
echo " Image  : $IMGNAME"
echo "==============================================================="
echo ""
# ⛔ STILL AN EXACT MATCH. What changed in 1.9 is only the number of attempts:
# a mistyped serial used to power the unit off, which meant rebooting it to try
# again, and a 20 character serial typed by hand gets mistyped. Three tries, and
# the answer still has to be right. Typing 'stop' leaves without writing.
if [ -n "$TGT_SERIAL" ]; then
    want="$TGT_SERIAL"
    echo " To confirm, type this disk's serial number exactly:"
else
    # No serial to type back. Do not fall through to a weaker confirmation
    # silently: say so, and make the operator type the disk name and its size.
    want="$tgt $(human "$TGT_BYTES")"
    echo " This disk reports no serial number, so type its name and size,"
    echo " exactly as shown above, separated by one space:"
fi
conf=""
ct=0
while [ "$ct" -lt 3 ]; do
    ct=$((ct + 1))
    printf '   %s\n > ' "$want"
    read -r conf 2>/dev/null || bail "Not confirmed. Nothing was written."
    conf=$(printf '%s' "$conf" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ "$conf" = "$want" ] && break
    case "$(printf '%s' "$conf" | tr 'A-Z' 'a-z')" in
        s|stop|cancel|quit|exit|q|no|n)
            bail "Stopped at the confirmation. Nothing was written." ;;
    esac
    conf=""
    if [ "$ct" -lt 3 ]; then
        echo ""
        echo " That did not match. Type it exactly as shown above, or type"
        echo " stop to leave this computer's disk alone."
        echo ""
    fi
done
[ -n "$conf" ] || bail "The confirmation did not match after three tries. Nothing was written."

# --- 6. restore -------------------------------------------------------------
mkdir -p /home/partimag 2>/dev/null
mountpoint -q /home/partimag || mount --bind "$REPO" /home/partimag \
    || bail "Could not open the image folder on the USB drive."

log "restoring $IMGNAME onto /dev/$tgt"
echo ""
echo " Restoring. This takes a while and must not be interrupted."
echo ""

# -k1  rescale the partition table proportionally for this disk
# -r   grow the filesystem to fill its new partition afterwards
# -e1/-e2/-g auto  fix up the MBR/boot loader for the new geometry
# NO -icds, deliberately. It only silences the destination size check, which is
# the very check we just did properly ourselves, and it shrinks nothing.
/usr/sbin/ocs-sr -g auto -e1 auto -e2 -r -j2 -k1 -p true restoredisk "$IMGNAME" "$tgt"
RC=$?
log "ocs-sr exit=$RC"

# --- 7. clear the chkdsk Clonezilla's own expand schedules -------------------
# ocs-resize-part runs `ntfsresize -f -f` in batch mode, and on v2022.10.3 that
# still schedules a consistency check despite what the help text claims. Left
# alone, every deployed unit runs chkdsk on its first boot. Verified 2026-09-04.
if [ $RC -eq 0 ]; then
    for p in $(lsblk -ln -o NAME,FSTYPE "/dev/$tgt" 2>/dev/null | awk '$2=="ntfs"{print $1}'); do
        out=$(ntfsfix -d "/dev/$p" 2>&1)
        case "$out" in
            *"was processed successfully"*) log "cleared chkdsk flag on /dev/$p" ;;
            *) log "could not clear chkdsk flag on /dev/$p: $out" ;;
        esac
    done
fi

sync
echo ""
if [ $RC -eq 0 ]; then
    echo " DEPLOY COMPLETE. Remove the USB drive and start the computer."
else
    echo " DEPLOY FAILED (code $RC). Do not use this computer."
    echo " The log is on the USB in TOAST\\logs\\deploy.log."
fi
echo ""
echo " Press Enter to power off."
read -r _ 2>/dev/null || true
toast_poweroff