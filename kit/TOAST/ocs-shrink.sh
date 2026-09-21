#!/bin/sh
# TOAST Image Capture Kit - shrink the Windows filesystem before capture, and
# always put it back afterwards.
#
# WHY THIS EXISTS
# partclone stores used blocks against their absolute offsets in the filesystem,
# and NTFS keeps a backup boot sector at the last sector of the volume. So a
# 953 GiB filesystem always writes past the end of a smaller partition, however
# little data it holds, and NO restore-time flag can fix that: -icds only
# silences the size check, -r runs after a successful restore. The shrink has to
# happen before the bitmap is taken. That is what FOG does at capture time and
# why FOG can restore to a smaller disk when stock Clonezilla cannot.
#
# SUBCOMMANDS
#   shrink <disk>          find the Windows NTFS volume on <disk>, shrink it
#   expand                 put it back, from the state file
#   repair                 same as expand, for the standalone menu entry
#   shrink-volume <dev>    engine only, on one NTFS device or image file
#   expand-volume <dev>    engine only
#
# The engine subcommands take a device OR a plain file, which is what lets the
# whole shrink/expand path be tested on the server against an NTFS image with no
# block device and no unit involved.
#
# ⛔ Every ntfsresize call that touches an already-resized volume MUST pass -f.
# A successful shrink SCHEDULES A CHKDSK, which marks the volume, and ntfsresize
# then refuses it outright ("Volume is scheduled for check"). Without -f the
# expand-back silently does nothing and the unit is left with a small filesystem
# inside a large partition. Measured 2026-09-04, see AUTOCAPTURE-AUTODEPLOY.md.
#
# ⛔ ntfsresize's documented "-f twice disables chkdsk scheduling" DOES NOT WORK
# on v2022.10.3, the version Clonezilla 3.3.3-15 ships. Tested. `ntfsfix -d` is
# the only thing that clears the flag, and it has to run after the shrink too,
# not just after the expand: the shrink happens BEFORE the capture, so the flag
# lands inside the image and every deployed unit would chkdsk on first boot.

# Not `set -e`: this script's whole job is to leave the filesystem in a known
# state, so every failure is handled explicitly rather than by exiting.
set -u

MEDIUM=""
for m in ${TOAST_MEDIUM:-} /run/live/medium /lib/live/mount/medium; do
    [ -n "$m" ] && [ -d "$m/TOAST" ] && { MEDIUM="$m"; break; }
done
[ -n "$MEDIUM" ] || MEDIUM=${TOAST_MEDIUM:-/run/live/medium}

STATE="$MEDIUM/TOAST/config/shrink.state"
LOG="$MEDIUM/TOAST/logs/shrink.log"
MNT=/tmp/toast_shrink_mnt

# Slack above the ntfsresize minimum. This is a SAFETY margin for the restore,
# NOT a lever on upload size: partclone captures used blocks only, so a 46 GiB
# and a 36 GiB filesystem holding the same data produce near-identical images.
# Shrinking harder only makes ntfsresize relocate more data on the customer's
# disk for no gain.
SLACK_PCT=${SLACK_PCT:-15}
SLACK_MIN_MB=${SLACK_MIN_MB:-3072}

# Volatile files Windows recreates by itself on the deployed unit.
#
# ⛔ MEASURED 2026-09-04, and NOT for the reason you would assume. Removing these
# cut the raw data partclone reads by 61% (30.99 -> 12.05 GB on a real customer
# volume) but changed the COMPRESSED image by under 1%, because pagefile and
# hiberfil are mostly zeros and compress to almost nothing anyway. Do not keep
# this step for image size. Keep it because it roughly halves capture time
# (876 -> 404 s measured) and because it takes the shrink target from 35.7 GB
# down to 15.3 GB, which is what decides whether a restore fits a small disk.
STRIP_VOLATILE=${STRIP_VOLATILE:-yes}

log() {
    mount -o remount,rw "$MEDIUM" 2>/dev/null
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$LOG" 2>/dev/null
    echo "TOAST: $*"
}

die() {
    echo ""
    echo "==============================================================="
    echo " TOAST IMAGE CAPTURE - CANNOT CONTINUE"
    echo "==============================================================="
    echo " $1"
    echo ""
    echo " Nothing has been changed on this computer's disk."
    echo " Please contact your supplier and quote this message."
    echo "==============================================================="
    echo ""
    log "ABORT: $1"
    exit 1
}

# Everything shared by the kit scripts. This one only prompts in a single place,
# the multi-boot choice, but it must retry and read words exactly like every
# other prompt on the stick. See ocs-common.sh.
TOAST_SCRIPTS=$(dirname "$0" 2>/dev/null)
case "$TOAST_SCRIPTS" in ''|.) TOAST_SCRIPTS="$MEDIUM/TOAST/scripts" ;; esac
[ -r "$TOAST_SCRIPTS/ocs-common.sh" ] || TOAST_SCRIPTS="$MEDIUM/TOAST/scripts"
[ -r "$TOAST_SCRIPTS/ocs-common.sh" ] \
    || die "A file this kit needs is missing from the USB drive (TOAST\\scripts\\ocs-common.sh)."
. "$TOAST_SCRIPTS/ocs-common.sh"

need() {
    command -v "$1" >/dev/null 2>&1 || die "Required tool '$1' is missing from the boot image."
}

# --- helpers -----------------------------------------------------------------

# Size of a device or a plain file, in bytes.
dev_bytes() {
    if [ -b "$1" ]; then
        blockdev --getsize64 "$1"
    else
        # stat -c differs across busybox/coreutils; wc -c would read the whole file.
        stat -c %s "$1" 2>/dev/null || stat -f %z "$1"
    fi
}

# BitLocker check. A BitLocker volume carries "-FVE-FS-" where plain NTFS carries
# "NTFS    " in the boot sector OEM ID at offset 3. Detect it, never ask: an
# encrypted volume cannot be shrunk, and partclone would raw-copy every sector,
# turning a 40 GB install into a whole-disk image. The kit already requires FULL
# decryption; suspended is not enough, because suspending leaves every sector
# encrypted.
is_bitlocker() {
    oem=$(dd if="$1" bs=1 skip=3 count=8 2>/dev/null | tr -d '\0')
    case "$oem" in
        *-FVE-FS-*) return 0 ;;
        *) return 1 ;;
    esac
}

# Is the volume clean? Capture the output FIRST and match on the variable.
#
# ⛔ `ntfsinfo ... | grep -q` is a trap here: grep -q exits on first match, the
# producer dies on SIGPIPE, and under pipefail a SUCCESSFUL match reads as a
# failure. Same class of bug as the touch-capability checks in workflow.sh.
volume_is_clean() {
    out=$(ntfsinfo -m "$1" 2>&1)
    case "$out" in
        *"scheduled for check"*)  return 1 ;;
        *"Volume Flags: 0x0000"*) return 0 ;;
    esac
    # No recognised answer either way. Treat as not clean rather than guessing.
    return 1
}

# Cache the whole `ntfsresize --info` output once, in a file, so that every
# failure can report what ntfsresize actually said.
#
# ⛔ The first version threw this output away and died with a generic "could not
# work out how far the filesystem can be shrunk". That is exactly what a unit hit
# on the bench on 2026-09-04 and there was nothing in the log to say why. The
# output is the diagnosis; keep it.
#
# -b is deliberate, and matches FOG: ntfsresize refuses a volume whose bad sector
# list it cannot read unless told to support bad sectors. A real unit that has
# been in service is far more likely to have one than a fresh fixture.
NTFS_INFO_OUT=/tmp/toast_ntfsresize_info
ntfs_info() {
    ntfsresize --info -f -b "$1" > "$NTFS_INFO_OUT" 2>&1
    return 0
}

# Copy the interesting part of that output into the log on the stick, so support
# gets it without needing the console.
log_ntfs_info() {
    [ -r "$NTFS_INFO_OUT" ] || return 0
    log "---- ntfsresize --info output begins ----"
    grep -viE 'percent completed' "$NTFS_INFO_OUT" | while IFS= read -r l; do
        [ -n "$l" ] && log "  $l"
    done
    log "---- ntfsresize --info output ends ----"
}

# Is the filesystem structurally sound? This is NOT the same question as
# volume_is_clean().
#
# ⛔ A volume can have Volume Flags 0x0000, i.e. no chkdsk scheduled and a clean
# shutdown, and still be internally inconsistent. A real unit on 2026-09-04 had
# 205 "extra cluster in $Bitmap" mismatches with a perfectly clean flag, so the
# clean check passed and the failure only surfaced later as a missing minimum
# size. ntfsresize refuses such a volume and says so precisely; only Windows
# chkdsk /f can repair it.
#
# Reads the cached output, so call ntfs_info (or ntfs_current_bytes) first.
volume_is_consistent() {
    case "$(cat "$NTFS_INFO_OUT" 2>/dev/null)" in
        *"NTFS is inconsistent"*|*"Filesystem check failed"*|*"Cluster accounting failed"*)
            return 1 ;;
    esac
    return 0
}

# Minimum size ntfsresize will accept, in bytes.
ntfs_min_bytes() {
    ntfs_info "$1"
    sed -n 's/.*You might resize at \([0-9]\+\) bytes.*/\1/p' "$NTFS_INFO_OUT" | head -1
}

# Fallback when ntfsresize will not state a minimum: derive one from the space it
# says is in use. The DRY RUN is the real gate either way, so a computed target
# that ntfsresize refuses costs nothing but a clear abort.
ntfs_used_bytes() {
    mb=$(sed -n 's/^Space in use *: *\([0-9]\+\) MB.*/\1/p' "$NTFS_INFO_OUT" | head -1)
    [ -n "$mb" ] || return 1
    echo $((mb * 1048576))
}

ntfs_current_bytes() {
    ntfs_info "$1"
    sed -n 's/^Current volume size: \([0-9]\+\) bytes.*/\1/p' "$NTFS_INFO_OUT" | head -1
}

# Clear the chkdsk that ntfsresize schedules. See the header note.
clear_dirty() {
    out=$(ntfsfix -d "$1" 2>&1)
    case "$out" in
        *"was processed successfully"*) log "chkdsk flag cleared on $1"; return 0 ;;
    esac
    log "WARNING: could not clear the chkdsk flag on $1: $out"
    return 1
}

# --- engine ------------------------------------------------------------------

shrink_volume() {
    dev="$1"
    fstype="${2:-}"
    [ -n "$fstype" ] || fstype=$(blkid -s TYPE -o value "$dev" 2>/dev/null)

    case "$fstype" in
        ntfs) : ;;
        ext2|ext3|ext4) shrink_volume_ext "$dev" "$fstype"; return $? ;;
        *)
            # xfs cannot shrink at all, and btrfs needs a different tool. Skip
            # rather than abort: a capture without a shrink is still a good
            # capture, it just cannot be restored onto a smaller disk.
            log "filesystem '$fstype' on $dev cannot be shrunk by this kit; capturing at full size"
            echo ""
            echo " Note: this disk's filesystem ($fstype) cannot be made smaller,"
            echo " so the image will only restore onto a disk of the same size or"
            echo " larger. The capture itself is unaffected."
            echo ""
            write_state "$dev" "0" "$(dev_bytes "$dev")" "0" "notshrunk"
            return 0 ;;
    esac

    need ntfsresize; need ntfsfix; need dd

    is_bitlocker "$dev" && die "This disk is encrypted with BitLocker. Turn BitLocker OFF completely and let it finish decrypting, then run this again. Suspending BitLocker is not enough."

    if ! volume_is_clean "$dev"; then
        die "Windows was not shut down cleanly, so its filesystem is marked for checking. Start Windows, let it finish starting, then shut it down fully (Start > Shut down, not Restart or Sleep) and run this again."
    fi

    part_bytes=$(dev_bytes "$dev")
    cur=$(ntfs_current_bytes "$dev")
    [ -n "$cur" ] || die "Could not read the size of the Windows filesystem on $dev."

    # ⛔ CHECKED BEFORE ANYTHING IS WRITTEN, and that ordering is the point. The
    # first version stripped the volatile files first and only then discovered
    # the filesystem was unfit to touch: on the 2026-09-04 unit it had already
    # deleted 9.2 GB from a customer's disk before aborting. Windows recreates
    # those files, so nothing was lost, but writing to a filesystem we are about
    # to declare damaged is exactly the wrong order.
    if ! volume_is_consistent; then
        n=$(grep -c 'Cluster accounting failed' "$NTFS_INFO_OUT" 2>/dev/null || echo 0)
        log "NTFS is structurally inconsistent (${n} cluster accounting messages); nothing was changed"
        log_ntfs_info
        die "This computer's Windows filesystem has errors, so it cannot be captured yet. NOTHING has been changed. To fix it: start Windows, open Command Prompt as administrator, run   chkdsk C: /f   answer Y to schedule it, then restart the computer TWICE and let it finish checking both times. Then run this again."
    fi

    if [ "$STRIP_VOLATILE" = yes ]; then
        strip_volatile "$dev"
    fi

    min=$(ntfs_min_bytes "$dev")
    if [ -z "$min" ]; then
        # ntfsresize would not state a minimum. Say why, in the log, then try a
        # target computed from the space in use and let the dry run decide.
        log "ntfsresize did not report a minimum size for $dev; falling back to space-in-use"
        log_ntfs_info
        reason=$(grep -iE '^ERROR|failed|bad sector|not clean|hibernat|scheduled for check' "$NTFS_INFO_OUT" 2>/dev/null | head -1)
        [ -n "$reason" ] && log "ntfsresize said: $reason"

        used=$(ntfs_used_bytes) || used=""
        if [ -z "$used" ]; then
            die "Could not read how much space is in use on the Windows partition. ${reason:-No reason was reported.} If that mentions clusters or an inconsistent filesystem, run   chkdsk C: /f   in Windows as administrator and restart TWICE, then try again. The full output is in TOAST\\logs\\shrink.log."
        fi
        # Space in use is reported to the nearest MB and ntfsresize needs room to
        # relocate, so be generous here: this path is a fallback, not a target.
        min=$(awk -v u="$used" 'BEGIN { printf "%d", u * 1.10 }')
        log "fallback minimum from space-in-use: ${min}B"
    fi

    target=$(awk -v m="$min" -v c="$cur" -v p="$SLACK_PCT" -v f="$SLACK_MIN_MB" '
        BEGIN {
            slack = m * p / 100
            floor = f * 1048576
            if (slack < floor) slack = floor
            t = m + slack
            if (t > c) t = c
            printf "%d", t
        }')

    log "volume $dev: partition ${part_bytes}B, filesystem ${cur}B, minimum ${min}B, target ${target}B"

    if [ "$target" -ge "$cur" ]; then
        log "no shrink needed: target is not smaller than the current filesystem"
        write_state "$dev" "$cur" "$part_bytes" "$cur" "notshrunk" "ntfs"
        return 0
    fi

    # Dry run must pass before anything is written. ntfsresize's own advice.
    out=$(ntfsresize -n -b --size "$target" "$dev" 2>&1)
    case "$out" in
        *"ended successfully"*) : ;;
        *)
            log "dry run FAILED for target ${target}B"
            echo "$out" | grep -viE 'percent completed' | while IFS= read -r l; do
                [ -n "$l" ] && log "  $l"
            done
            log_ntfs_info
            why=$(echo "$out" | grep -iE '^ERROR|failed|bad sector|not clean|hibernat|scheduled for check' | head -1)
            die "The test run of the resize did not succeed, so nothing was changed. ${why:-No reason was reported.} The full output is in TOAST\\logs\\shrink.log - please send that file to your supplier." ;;
    esac
    log "dry run passed"

    # State is written BEFORE the real resize, so a power loss between the two
    # still leaves the repair entry something to act on.
    write_state "$dev" "$cur" "$part_bytes" "$target" "shrinking" "ntfs"

    out=$(printf 'y\n' | ntfsresize -b --size "$target" "$dev" 2>&1)
    case "$out" in
        *"Successfully resized"*) : ;;
        *) log "shrink failed: $out"
           die "Resizing the Windows filesystem failed. The unit has not been captured. Details are in TOAST\\logs\\shrink.log." ;;
    esac
    log "shrunk to ${target}B"

    # The shrink scheduled a chkdsk. Clear it now, BEFORE the capture, or the
    # flag is baked into the image and every deployed unit chkdsks on first boot.
    clear_dirty "$dev"

    write_state "$dev" "$cur" "$part_bytes" "$target" "shrunk" "ntfs"
    return 0
}

# ext2/3/4. resize2fs refuses a filesystem that has not been checked, so
# e2fsck -f -y comes first. That is a write, and it is the same thing FOG does
# in funcs.sh before its own resize2fs call.
shrink_volume_ext() {
    dev="$1"; fstype="$2"
    need e2fsck; need resize2fs; need dumpe2fs

    part_bytes=$(dev_bytes "$dev")

    out=$(e2fsck -f -y "$dev" 2>&1); rc=$?
    # 0 clean, 1 errors fixed, 2 errors fixed and a reboot would be wanted.
    # 4 and above means errors it could NOT fix, and resize2fs must not run.
    if [ "$rc" -ge 4 ]; then
        log "e2fsck could not repair $dev (exit $rc)"
        echo "$out" | tail -20 | while IFS= read -r l; do [ -n "$l" ] && log "  $l"; done
        die "This computer's filesystem has errors that could not be repaired automatically, so it cannot be captured yet. NOTHING has been changed. Boot the system and run   sudo e2fsck -f $dev   from rescue media, then try again."
    fi
    log "e2fsck on $dev returned $rc (0 clean, 1 or 2 fixed)"

    bs=$(dumpe2fs -h "$dev" 2>/dev/null | sed -n 's/^Block size: *\([0-9]\+\).*/\1/p' | head -1)
    : "${bs:=4096}"
    min_blocks=$(resize2fs -P "$dev" 2>/dev/null | sed -n 's/.*: *\([0-9]\+\).*/\1/p' | head -1)
    [ -n "$min_blocks" ] || die "Could not work out how far the filesystem on $dev can be shrunk. NOTHING has been changed."

    cur=$(( $(dumpe2fs -h "$dev" 2>/dev/null | sed -n 's/^Block count: *\([0-9]\+\).*/\1/p' | head -1) * bs ))
    min=$((min_blocks * bs))
    target=$(awk -v m="$min" -v c="$cur" -v p="$SLACK_PCT" -v f="$SLACK_MIN_MB" '
        BEGIN { sl = m*p/100; fl = f*1048576; if (sl < fl) sl = fl
                t = m + sl; if (t > c) t = c; printf "%d", t }')
    log "volume $dev ($fstype): partition ${part_bytes}B, filesystem ${cur}B, minimum ${min}B, target ${target}B"

    if [ "$target" -ge "$cur" ]; then
        log "no shrink needed"
        write_state "$dev" "$cur" "$part_bytes" "$cur" "notshrunk" "$fstype"
        return 0
    fi

    tmb=$((target / 1048576))
    write_state "$dev" "$cur" "$part_bytes" "$target" "shrinking" "$fstype"
    out=$(resize2fs "$dev" "${tmb}M" 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
        log "resize2fs failed (exit $rc)"
        echo "$out" | while IFS= read -r l; do [ -n "$l" ] && log "  $l"; done
        die "Making the filesystem smaller failed, so the unit has not been captured. The full output is in TOAST\\logs\\shrink.log."
    fi
    log "shrunk to ${tmb}M"
    write_state "$dev" "$cur" "$part_bytes" "$target" "shrunk" "$fstype"
    return 0
}

expand_volume_ext() {
    dev="$1"
    need e2fsck; need resize2fs
    e2fsck -f -y "$dev" >/dev/null 2>&1
    out=$(resize2fs "$dev" 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
        log "expand FAILED on $dev: $out"
        return 1
    fi
    log "expanded $dev to fill its partition"
    return 0
}

expand_volume() {
    dev="$1"
    efs="${2:-}"
    [ -n "$efs" ] || efs=$(blkid -s TYPE -o value "$dev" 2>/dev/null)
    case "$efs" in
        ext2|ext3|ext4) expand_volume_ext "$dev"; return $? ;;
    esac
    need ntfsresize; need ntfsfix

    part_bytes=$(dev_bytes "$dev")

    # -f is MANDATORY. Without it ntfsresize refuses a volume that a previous
    # resize marked, and the expand silently does nothing. No --size: ntfsresize
    # with no size grows the filesystem to fill the whole device, which is
    # exactly "put it back".
    out=$(printf 'y\n' | ntfsresize -f "$dev" 2>&1)
    case "$out" in
        *"Successfully resized"*|*"Nothing to do"*) : ;;
        *) log "expand FAILED on $dev: $out"
           return 1 ;;
    esac

    clear_dirty "$dev"

    now=$(ntfs_current_bytes "$dev")
    log "expanded $dev: filesystem now ${now}B in a ${part_bytes}B partition"

    # Verify it really filled the partition. NTFS sits a little under the
    # partition size by design (the backup boot sector), so allow a small delta
    # rather than demanding equality.
    ok=$(awk -v n="$now" -v p="$part_bytes" 'BEGIN { print (n > p - 1048576) ? "yes" : "no" }')
    [ "$ok" = yes ] || { log "expand VERIFY FAILED: ${now}B does not fill ${part_bytes}B"; return 1; }
    return 0
}

# --- state -------------------------------------------------------------------

write_state() {
    mount -o remount,rw "$MEDIUM" 2>/dev/null
    mkdir -p "$(dirname "$STATE")" 2>/dev/null
    {
        echo "DEVICE='$1'"
        echo "ORIG_FS_BYTES='$2'"
        echo "PART_BYTES='$3'"
        echo "TARGET_BYTES='$4'"
        echo "PHASE='$5'"
        echo "FSTYPE='${6:-}'"
        echo "STAMP='$(date -u +%Y-%m-%dT%H:%M:%SZ)'"
    } > "$STATE" 2>/dev/null
    sync
}

# Parsed, never sourced. Same reasoning as capture.conf in ocs-prerun.sh: this
# file lives on a FAT32 stick a customer can open in Notepad, so a CRLF save or
# a value with a space must not become something the shell executes.
read_state() {
    ST_DEVICE=""; ST_ORIG=""; ST_PART=""; ST_TARGET=""; ST_PHASE=""; ST_FSTYPE=""
    [ -r "$STATE" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(printf '%s' "$line" | tr -d '\r')
        case "$line" in ""|"#"*) continue ;; esac
        key=${line%%=*}; [ "$key" = "$line" ] && continue
        val=${line#*=}
        case "$val" in \'*\') val=${val#\'}; val=${val%\'} ;; esac
        case "$key" in
            DEVICE)       ST_DEVICE=$val ;;
            ORIG_FS_BYTES) ST_ORIG=$val  ;;
            PART_BYTES)   ST_PART=$val   ;;
            TARGET_BYTES) ST_TARGET=$val ;;
            PHASE)        ST_PHASE=$val  ;;
            FSTYPE)       ST_FSTYPE=$val ;;
        esac
    done < "$STATE"
    [ -n "$ST_DEVICE" ]
}

clear_state() {
    mount -o remount,rw "$MEDIUM" 2>/dev/null
    rm -f "$STATE" 2>/dev/null
    sync
}

# --- volatile file removal ---------------------------------------------------

strip_volatile() {
    dev="$1"
    need ntfs-3g
    mkdir -p "$MNT" 2>/dev/null

    # Mounted WITHOUT remove_hiberfile on purpose. If the volume is genuinely
    # hibernated, ntfs-3g refuses, and refusing is correct: a hibernated volume
    # means Windows did not shut down, and silently discarding the session to
    # get a smaller image is not ours to do.
    out=$(mount -t ntfs-3g "$dev" "$MNT" 2>&1)
    if [ $? -ne 0 ]; then
        case "$out" in
            *hibernat*)
                die "Windows is hibernated rather than shut down. Start Windows, let it finish starting, then shut it down fully (Start > Shut down) and run this again." ;;
            *)
                log "could not mount $dev to remove volatile files, continuing without: $out"
                return 0 ;;
        esac
    fi

    freed=0
    for f in pagefile.sys hiberfil.sys swapfile.sys DumpStack.log.tmp; do
        if [ -f "$MNT/$f" ]; then
            sz=$(stat -c %s "$MNT/$f" 2>/dev/null || echo 0)
            if rm -f "$MNT/$f" 2>/dev/null; then
                freed=$((freed + sz))
                log "removed $f (${sz}B) - Windows recreates it on the deployed unit"
            else
                log "could not remove $f, continuing"
            fi
        fi
    done

    sync
    umount "$MNT" 2>/dev/null
    log "volatile files freed ${freed}B"
    return 0
}

# --- disk-level discovery ----------------------------------------------------

# Find the volume holding the operating system, and say what filesystem it is.
#
# ⛔ THIS USED TO BE WINDOWS-ONLY, and that was a real defect, not just wording.
# It looked exclusively for an NTFS partition containing \Windows\System32, so on
# a Linux unit it found nothing, died, and ocs-capture.sh treated that as fatal:
# TOAST refused to capture a Linux machine at all. The kit is used for Linux
# images too. Fixed 2026-09-05.
#
# Echoes one line per candidate: "<device> <fstype> <description>".
#
# ⛔ It lists ALL of them and does not choose. The first version returned the
# first match and stopped, which on a dual-boot disk, a second Windows install,
# or a recovery volume that happens to look bootable would have silently picked
# one at random and shrunk it. Ambiguity is resolved by asking, the same way
# ocs-prerun.sh refuses rather than guessing when a serial matches two disks.
find_os_volumes() {
    disk="$1"
    need lsblk
    mkdir -p "$MNT" 2>/dev/null
    for line in $(lsblk -ln -o NAME,FSTYPE "/dev/$disk" 2>/dev/null | sed 1d | awk 'NF>1{print $1":"$2}'); do
        pn=${line%%:*}; pfs=${line##*:}
        dev="/dev/$pn"
        [ -b "$dev" ] || continue
        case "$pfs" in
            ntfs)
                is_bitlocker "$dev" && continue
                if mount -t ntfs-3g -o ro "$dev" "$MNT" 2>/dev/null; then
                    [ -d "$MNT/Windows/System32" ] && echo "$dev $pfs Windows"
                    umount "$MNT" 2>/dev/null
                fi
                ;;
            ext2|ext3|ext4)
                if mount -o ro "$dev" "$MNT" 2>/dev/null; then
                    # /etc and /usr together are a far better test of a root
                    # filesystem than either alone, and exclude /boot.
                    if [ -d "$MNT/etc" ] && [ -d "$MNT/usr" ]; then
                        nm=$(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}/\1/p' "$MNT/etc/os-release" 2>/dev/null | head -1)
                        echo "$dev $pfs ${nm:-Linux}" | tr -s ' '
                    fi
                    umount "$MNT" 2>/dev/null
                fi
                ;;
            *) continue ;;
        esac
    done
}

# One candidate: use it. Several: ask. None: say so and let the capture go ahead
# without a shrink, because a full-size image is still a good image.
choose_os_volume() {
    disk="$1"
    list=$(find_os_volumes "$disk")
    count=$(printf '%s\n' "$list" | grep -c . || true)

    if [ "${count:-0}" -eq 0 ]; then
        echo "NONE"
        return 0
    fi
    if [ "$count" -eq 1 ]; then
        printf '%s\n' "$list"
        return 0
    fi

    # ⛔ Everything the operator sees goes to STDERR. Only the chosen line may
    # go to stdout, because the caller captures this function.
    {
    echo ""
    echo "==============================================================="
    echo " MORE THAN ONE OPERATING SYSTEM ON THIS DISK"
    echo "==============================================================="
    echo " This disk holds more than one system, so it is not obvious which"
    echo " one should be made smaller before the copy is taken. Choose the"
    echo " one this image is FOR."
    echo ""
    i=0
    printf '%s\n' "$list" | while IFS= read -r l; do
        [ -n "$l" ] || continue
        i=$((i + 1))
        d=$(echo "$l" | awk '{print $1}')
        f=$(echo "$l" | awk '{print $2}')
        w=$(echo "$l" | cut -d' ' -f3-)
        sz=$(dev_bytes "$d" 2>/dev/null || echo 0)
        printf '   %d)  %s   %s   %s\n' "$i" "$w" "$f" "$(awk -v b="$sz" 'BEGIN{printf "%.1f GB", b/1e9}')"
    done
    echo ""
    } >&2
    # Three tries. A mistyped digit here used to abort the whole capture, which
    # is a long walk back for one keystroke. Only BADPICK, on stdout, ends it.
    pick=$(ask_number "$count" "$(printf ' Type the number of the system this image is for (1-%d), or stop: ' "$count")")
    case $? in
        0) : ;;
        2) echo "STOPPED"; return 0 ;;
        *) echo "BADPICK"; return 0 ;;
    esac
    printf '%s\n' "$list" | sed -n "${pick}p"
}

# --- subcommands -------------------------------------------------------------

case "${1:-}" in
    shrink)
        disk="${2:-}"
        [ -n "$disk" ] || die "shrink needs a disk name, for example sda."
        found=$(choose_os_volume "$disk")
        case "$found" in
            STOPPED)
                die "Stopped at the choice of which system to capture. Nothing has been changed." ;;
            BADPICK)
                die "No system was chosen after three tries. Nothing has been changed." ;;
            NONE)
                log "no shrinkable operating system volume found on /dev/$disk; capturing at full size"
                echo ""
                echo " Note: no filesystem on this disk can be made smaller by this"
                echo " kit, so the image will only restore onto a disk of the same"
                echo " size or larger. The capture itself is unaffected."
                echo ""
                exit 0 ;;
        esac
        vol=$(echo "$found" | awk '{print $1}')
        volfs=$(echo "$found" | awk '{print $2}')
        voldesc=$(echo "$found" | cut -d' ' -f3-)
        [ -n "$vol" ] && [ -n "$volfs" ] || die "Could not identify the operating system partition on /dev/$disk."
        log "preparing $vol ($volfs, $voldesc) on /dev/$disk"
        shrink_volume "$vol" "$volfs"
        ;;
    expand|repair)
        if ! read_state; then
            log "nothing to expand: no shrink state recorded"
            exit 0
        fi
        if [ "$ST_PHASE" = notshrunk ]; then
            log "filesystem was never shrunk, nothing to expand"
            clear_state
            exit 0
        fi
        [ -b "$ST_DEVICE" ] || [ -f "$ST_DEVICE" ] || die "The recorded Windows partition $ST_DEVICE is not present."
        if expand_volume "$ST_DEVICE" "$ST_FSTYPE"; then
            clear_state
            log "expand complete"
            exit 0
        fi
        # State deliberately KEPT on failure: it is the only record that a
        # shrink is still outstanding, and the repair menu entry needs it.
        log "expand did not succeed; state kept so the repair entry can retry"
        exit 1
        ;;
    shrink-volume) shrink_volume "${2:?device or image file required}" "${3:-}" ;;
    expand-volume) expand_volume "${2:?device or image file required}" "${3:-}" ;;
    state)         read_state && cat "$STATE" || echo "no state" ;;
    *)
        echo "usage: $0 {shrink <disk>|expand|repair|shrink-volume <dev>|expand-volume <dev>|state}" >&2
        exit 2
        ;;
esac
