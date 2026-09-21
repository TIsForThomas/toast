#!/bin/sh
# TOAST Image Capture Kit - resolve target disk from capture.conf
# Runs as ocs_prerun. Writes /tmp/toast_target and /tmp/toast_image.
# Locate the boot medium. live-boot changed this path: modern builds use
# /run/live/medium, older ones /lib/live/mount/medium. Probe, never assume.
MEDIUM=""
for m in ${TOAST_MEDIUM:-} /run/live/medium /lib/live/mount/medium; do
    [ -n "$m" ] && [ -d "$m/TOAST" ] && { MEDIUM="$m"; break; }
done
[ -n "$MEDIUM" ] || MEDIUM=${TOAST_MEDIUM:-/run/live/medium}

CONF="$MEDIUM/TOAST/config/capture.conf"

fail() {
    echo ""
    echo "==============================================================="
    echo " TOAST IMAGE CAPTURE - CANNOT CONTINUE"
    echo "==============================================================="
    echo " $1"
    echo ""
    echo " Please contact your supplier and quote this message."
    echo "==============================================================="
    echo ""
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

# ⛔ A DELIBERATE "no" IS NOT A FAULT, and must not be reported as one.
#
# Until 1.9 every one of these paths called fail(), which prints "CANNOT
# CONTINUE ... contact your supplier and quote this message" and then exits 1
# WITHOUT powering off. Clonezilla runs ocs_live_run regardless of how the prerun
# exited, so ocs-capture.sh then added "the previous step did not say which disk
# to capture" underneath it. A customer who answered no on purpose was told they
# had a fault, told to contact support, and shown a second contradictory error.
# Confirmed from the harness evidence of 2026-09-04.
#
# Powering off here is what stops that second message: the unit is gone before
# ocs_live_run gets its turn.
stop_cleanly() {
    echo ""
    echo "==============================================================="
    echo " STOPPED - NOTHING WAS CHANGED"
    echo "==============================================================="
    echo " $1"
    echo ""
    echo " No image was captured and nothing on this computer was altered."
    echo " It is safe to start Windows normally."
    echo ""
    echo " This computer will power off in 20 seconds."
    echo "==============================================================="
    echo ""
    # TOAST_STOP_WAIT is for the test suite only; on a stick this is 20 seconds
    # so the message can be read before the screen goes dark.
    sleep "${TOAST_STOP_WAIT:-20}"
    toast_poweroff
    exit 1
}

# Charset rule for anything that becomes part of a directory name on a FAT32
# stick. Same rule the IMAGE_NAME check below applies, applied at entry instead.
# Lower-case, collapse anything outside the allowed charset to a single dash,
# and cap the length. The cap matters: a QEMU guest reports a 48-character DMI
# product name, and a real unit could too, which would make an unreadable image
# directory name.
sanitize() {
    printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9._-' '-' \
        | sed -e 's/-\{2,\}/-/g' -e 's/^[-.]*//' -e 's/-$//' \
        | cut -c1-"${2:-24}" | sed -e 's/-$//'
}

# Find the disk Windows is on, for the interactive path where there is no
# capture.conf to tell us. Never "the first disk": look for a disk carrying an
# NTFS volume that actually contains \Windows\System32, skip the USB we booted
# from and any other USB, and refuse rather than guess if several qualify.
discover_windows_disk() {
    _bootdisk=""
    _bd=$(awk -v m="$MEDIUM" '$2==m {print $1}' /proc/mounts | head -1)
    [ -n "$_bd" ] && _bootdisk=$(lsblk -no PKNAME "$_bd" 2>/dev/null | head -1)
    _found=""
    _n=0
    mkdir -p /tmp/toast_probe 2>/dev/null
    for _dp in /sys/block/*; do
        _d=$(basename "$_dp")
        case "$_d" in loop*|ram*|sr*|zram*|dm-*|md*|fd*) continue ;; esac
        [ -b "/dev/$_d" ] || continue
        [ "$_d" = "$_bootdisk" ] && continue
        case "$(readlink -f "$_dp")" in *usb*) continue ;; esac
        for _p in $(lsblk -ln -o NAME,FSTYPE "/dev/$_d" 2>/dev/null | awk '$2=="ntfs"{print $1}'); do
            if mount -t ntfs-3g -o ro "/dev/$_p" /tmp/toast_probe 2>/dev/null; then
                if [ -d /tmp/toast_probe/Windows/System32 ]; then
                    umount /tmp/toast_probe 2>/dev/null
                    _found="$_d"; _n=$((_n + 1))
                    break
                fi
                umount /tmp/toast_probe 2>/dev/null
            fi
        done
    done
    [ "$_n" -eq 1 ] || return 1
    echo "$_found"
}

# Accept what a person actually types. SHOUTING AT THE OPERATOR is not a safety
# feature: y, Y, yes, YES and Yes all mean yes.
#
# ⛔ This is deliberately NOT used for the two prompts that destroy data: the
# deploy entry still makes you type the target disk's own serial number, and
# write-kit still makes you type ERASE. Those exist to make you stop and read,
# and a one-key confirmation would defeat them.
is_yes() {
    case "$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z' | tr -d ' ')" in
        y|yes) return 0 ;;
        *) return 1 ;;
    esac
}

INTERACTIVE=no
if [ ! -r "$CONF" ]; then
    # No capture.conf means the Windows wizard has not run. For a customer that
    # is an error, but this is also how a bench capture starts, and a
    # person is sitting in front of it. Ask.
    INTERACTIVE=yes

    if [ -f "$MEDIUM/TOAST/config/capture.done" ]; then
        echo ""
        echo "==============================================================="
        echo " THIS USB ALREADY HOLDS A COMPLETED CAPTURE"
        echo "==============================================================="
        sed -n '1,2p' "$MEDIUM/TOAST/config/capture.done" | sed 's/^/   /'
        echo ""
        echo " Capturing again will replace it. Only do this if you know the"
        echo " machine has been sysprepped again since."
        echo ""
        ask_yes_no ' Capture again anyway? (yes/no): ' \
            || stop_cleanly "The capture already on this USB drive was kept."
    fi

    MODEL=$(dmidecode -s system-product-name 2>/dev/null | head -1)
    MODEL=$(sanitize "${MODEL:-unknown}")
    TODAY=$(date -u +%Y%m%d)

    echo ""
    echo "==============================================================="
    echo " TOAST BENCH CAPTURE"
    echo "==============================================================="
    echo " No customer answers were found on this USB, so this is being"
    echo " treated as a bench capture."
    echo ""
    echo " Model detected : ${MODEL}"
    echo " Date           : ${TODAY}"
    echo ""
    # A blank or unusable answer is a typo, not a decision to abandon the job.
    _co=""
    _cot=0
    while [ -z "$_co" ] && [ "$_cot" -lt 3 ]; do
        _cot=$((_cot + 1))
        _co=$(ask_line ' Customer or company short name (letters and digits): ') \
            || stop_cleanly "No customer or company name could be read, so the image could not be named."
        _co=$(sanitize "$_co")
        [ -n "$_co" ] || echo " That cannot be used in a file name. Letters and digits only, please."
    done
    [ -n "$_co" ] || stop_cleanly "No usable customer or company name was entered, so the image could not be named."

    # Image revision, so a later capture is told from this one by more than its
    # date, and two captures on the same day do not collide. Same question the
    # Windows wizard asks, so both paths produce the same name shape.
    _ver=$(ask_line ' Image version (Enter for v1, or v2, v3 ... for a later revision): ') || _ver=""
    _ver=$(sanitize "$_ver")
    [ -n "$_ver" ] || _ver=v1
    # Typing just "2" is the obvious thing to do, so accept it and make it v2.
    case "$_ver" in
        ''|*[!0-9]*) : ;;
        *) _ver="v$_ver" ;;
    esac

    # company - unit - version - capture date
    IMAGE_NAME="${_co}-${MODEL}-${_ver}-${TODAY}"

    echo ""
    echo " Image will be named: $IMAGE_NAME"
    echo ""

    TARGET=$(discover_windows_disk) || fail "Could not identify exactly one disk with Windows on it. Disconnect any extra disks and try again, or run the Windows step first so the disk is recorded."
    echo " Windows found on   : /dev/$TARGET"
    echo ""
    ask_yes_no ' Capture this disk? (yes/no): ' \
        || stop_cleanly "Nothing was captured."
fi

# Refuse to overwrite a good capture. Booting the kit a second time would
# otherwise re-capture from a machine that has since booted Windows and is no
# longer generalized, silently replacing a valid image with an unusable one.
if [ -f "$MEDIUM/TOAST/config/capture.done" ] && [ -r "$CONF" ]; then
    echo ""
    echo "==============================================================="
    echo " THIS UNIT HAS ALREADY BEEN CAPTURED"
    echo "==============================================================="
    echo " A completed capture is already on this USB drive:"
    echo ""
    sed -n '1,2p' "$MEDIUM/TOAST/config/capture.done" | sed 's/^/   /'
    echo ""
    echo " If the capture worked, nothing further is needed: start Windows"
    echo " and follow the upload steps."
    echo ""
    echo " There are two good reasons to carry on:"
    echo "   - the capture above went wrong and is being redone"
    echo "   - this is another computer, or another image, to be kept"
    echo "     alongside the one above"
    echo ""
    echo " Either way the computer must have been prepared again (step 1)"
    echo " since. Capturing a computer that has started Windows normally"
    echo " since step 1 produces an unusable image."
    echo "==============================================================="
    echo ""
    if ! ask_yes_no ' Capture again? (yes/no): '; then
        stop_cleanly "The capture already on this USB drive was kept."
    fi
fi

# Read capture.conf without sourcing it.
#
# Sourcing was the obvious thing and is the wrong thing. The file is written on
# Windows onto a FAT32 stick that a customer or a tech can open in Notepad: a
# CRLF save would put a carriage return inside IMAGE_NAME and therefore inside
# the image directory name, and an unquoted value containing a space (disk models
# routinely have one) would be read as a command to run. Parsing explicitly
# removes both, and means nothing in this file is ever executed.
IMAGE_NAME="${IMAGE_NAME:-}"; DISK_ID=""; DISK_ID_KIND=""; DISK_SERIAL=""
if [ "$INTERACTIVE" = no ]; then
while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s' "$line" | tr -d '\r')
    case "$line" in ""|"#"*) continue ;; esac
    key=${line%%=*}
    [ "$key" = "$line" ] && continue
    val=${line#*=}
    case "$val" in
        \'*\') val=${val#\'}; val=${val%\'} ;;
        \"*\") val=${val#\"}; val=${val%\"} ;;
    esac
    case "$key" in
        IMAGE_NAME)   IMAGE_NAME=$val   ;;
        DISK_ID)      DISK_ID=$val      ;;
        DISK_ID_KIND) DISK_ID_KIND=$val ;;
        DISK_SERIAL)  DISK_SERIAL=$val  ;;
    esac
done < "$CONF"
fi

# --- Identify the disk Windows is installed on -------------------------------
#
# Primary key is the identifier stored ON the disk itself: the GPT disk GUID, or
# the MBR disk signature for a legacy install. Windows and Linux read the exact
# same bytes for these, with no controller in the path -- which is the whole
# point. A vendor SERIAL is not equally safe: some drivers hand Windows an
# ATA serial with the byte pairs swapped, eMMC reports a different string on each
# side, and RAID/VMD or USB-bridge controllers may expose no serial at all. Any
# of those turns a capture into a support call.
#
# Serial is kept as a fallback for the one case the on-disk key cannot cover: a
# disk with no partition table Windows recognised well enough to report an id.
if [ "$INTERACTIVE" = no ]; then
[ -n "${DISK_ID:-}${DISK_SERIAL:-}" ] || fail "capture.conf identifies no disk (no DISK_ID and no DISK_SERIAL)."
[ -n "$IMAGE_NAME" ] || fail "capture.conf contains no IMAGE_NAME."
case "$IMAGE_NAME" in
    *[!A-Za-z0-9._-]*) fail "The image name in capture.conf contains characters that are not allowed." ;;
esac
fi

norm_id() { printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -e 's/^0x//' -e 's/[{}]//g'; }

# Every whole disk the kernel knows about, minus things that can never be the
# Windows disk. Partitions are not listed in /sys/block, so unlike the by-id
# scan this cannot accidentally select one.
whole_disks() {
    for d in /sys/block/*; do
        dev=$(basename "$d")
        case "$dev" in loop*|ram*|sr*|zram*|dm-*|md*|fd*) continue ;; esac
        [ -b "/dev/$dev" ] && echo "$dev"
    done
}

if [ "$INTERACTIVE" = yes ]; then
    MATCHES=1
    RESOLVED_BY="operator confirmation at the console"
else
TARGET=""
MATCHES=0
RESOLVED_BY=""

if [ -n "${DISK_ID:-}" ]; then
    want=$(norm_id "$DISK_ID")
    for dev in $(whole_disks); do
        got=$(norm_id "$(blkid -s PTUUID -o value "/dev/$dev" 2>/dev/null)")
        [ -n "$got" ] || continue
        if [ "$got" = "$want" ]; then
            TARGET="$dev"
            MATCHES=$((MATCHES + 1))
        fi
    done
    [ "$MATCHES" -gt 1 ] && fail "Disk id $DISK_ID matched more than one disk. Refusing to guess."
    [ "$MATCHES" -eq 1 ] && RESOLVED_BY="disk id ($DISK_ID_KIND)"
fi

if [ -z "$TARGET" ] && [ -n "${DISK_SERIAL:-}" ]; then
    # Skip *-part* links: a partition symlink also carries the disk serial, and
    # matching one captures a partition instead of the whole disk.
    for link in /dev/disk/by-id/*; do
        [ -e "$link" ] || continue
        case "$link" in *-part*) continue ;; esac
        case "$link" in *"$DISK_SERIAL"*)
            dev=$(basename "$(readlink -f "$link")")
            if [ "$dev" != "$TARGET" ]; then
                TARGET="$dev"
                MATCHES=$((MATCHES + 1))
            fi
            ;;
        esac
    done
    [ "$MATCHES" -gt 1 ] && fail "Serial $DISK_SERIAL matched more than one disk. Refusing to guess."
    [ "$MATCHES" -eq 1 ] && RESOLVED_BY="serial ($DISK_SERIAL)"
fi

if [ "$MATCHES" -eq 0 ]; then
    # Say what is actually the matter. One stick used on several units lands here
    # every time the Windows step was not re-run, and "could not find the disk"
    # reads like a hardware fault instead of a step that was skipped.
    if _other=$(discover_windows_disk); then
        fail "The answers on this USB drive were prepared on a DIFFERENT computer. This computer has Windows on /dev/$_other, but the USB is looking for disk id ${DISK_ID:-none}. Start Windows on this computer and run the preparation step (step 1) here first, then boot this USB again."
    fi
    fail "Could not find the disk Windows is installed on. Looked for disk id ${DISK_ID:-none} and serial ${DISK_SERIAL:-none}. If this USB drive was prepared on a different computer, run the preparation step (step 1) on this one first."
fi
fi

# Never capture the medium we booted from.
BOOTDEV=$(awk -v m="$MEDIUM" '$2==m {print $1}' /proc/mounts | head -1)
case "$BOOTDEV" in
    */"$TARGET"*) fail "Resolved target $TARGET is the TOAST USB itself. Refusing." ;;
esac

[ -b "/dev/$TARGET" ] || fail "Resolved target /dev/$TARGET is not a block device."

# --- a final go-ahead, even when everything was auto-filled -----------------
#
# The unattended path used to start capturing the moment it recognised the
# answers in capture.conf. That is too abrupt: the first thing a tech sees is a
# disk already being read. Asked for 2026-09-05 after exactly that happened on a
# sysprepped unit. So both paths now end with one deliberate confirmation, and
# the interactive path has already had its own.
if [ "$INTERACTIVE" = no ]; then
    echo ""
    echo "==============================================================="
    echo " READY TO CAPTURE"
    echo "==============================================================="
    echo " Image name : $IMAGE_NAME"
    echo " Disk       : /dev/$TARGET"
    echo " Resolved by: $RESOLVED_BY"
    echo ""
    echo " These answers came from the Windows step, so nothing needs"
    echo " typing. This is the last chance to stop."
    echo "==============================================================="
    echo ""
    ask_yes_no ' Start the capture? (yes/no): ' \
        || stop_cleanly "Nothing was captured."
fi

# --- an image of this name already there? three choices, not two -------------
#
# ⛔ UNTIL 1.9 THIS OFFERED ONLY REPLACE OR STOP, AND THAT MADE A SECOND IMAGE
# IMPOSSIBLE. On the customer path IMAGE_NAME comes from capture.conf and cannot
# be edited at the console, so every repeat capture arrived at the same name and
# the only way forward was to delete the image already there. Reported from the
# bench 2026-09-08: "it wants to replace the image on the disk rather than
# allowing me to capture a copy."
#
# Replacing is still offered and still reads first-class, because a capture that
# went wrong should be redone under the SAME name. That is also why an additional
# capture gets a suffix rather than an incremented version: the version in the
# name is for real revisions of a customer's image, not for retries or for a
# second unit.
EXISTING="$MEDIUM/home/partimag/$IMAGE_NAME"
if [ -d "$EXISTING" ]; then
    _sz=$(du -sh "$EXISTING" 2>/dev/null | cut -f1)
    _szb=$(du -sb "$EXISTING" 2>/dev/null | cut -f1)
    _when=$(date -r "$EXISTING" '+%Y-%m-%d %H:%M' 2>/dev/null || echo unknown)
    _free=$(df -h "$MEDIUM/home/partimag" 2>/dev/null | awk 'NR==2{print $4}')
    _freeb=$(df -B1 "$MEDIUM/home/partimag" 2>/dev/null | awk 'NR==2{print $4}')

    # A Clonezilla image directory always carries a 'parts' file. Without one
    # this is the wreckage of an interrupted capture, not an image, and saying so
    # is the difference between a confident choice and a guess.
    _state="a complete image"
    [ -f "$EXISTING/parts" ] || _state="INCOMPLETE - an earlier capture did not finish"

    echo ""
    echo "==============================================================="
    echo " AN IMAGE WITH THIS NAME IS ALREADY ON THIS USB DRIVE"
    echo "==============================================================="
    echo " Name    : $IMAGE_NAME"
    echo " Size    : ${_sz:-unknown}"
    echo " Created : $_when"
    echo " State   : $_state"
    echo " Free space left on this USB drive: ${_free:-unknown}"
    echo ""
    echo " What would you like to do?"
    echo ""
    echo "   1) Capture an ADDITIONAL image, and keep the one above"
    echo "      Nothing already on this drive is deleted. A name is"
    echo "      suggested for the new one and you can change it."
    echo ""
    echo "   2) REPLACE the image above with a new capture"
    echo "      The image above is deleted first. This is the right"
    echo "      choice when a capture went wrong and is being redone."
    echo ""
    echo "   3) STOP and change nothing"
    echo "      Nothing is captured and nothing is deleted."
    echo "==============================================================="
    echo ""
    _act=$(ask_option ' Type 1, 2 or 3: ' \
        'additional=1,a,add,additional,extra,another,both,keep,new,copy' \
        'replace=2,r,replace,overwrite,redo,again,over' \
        'stop=3,s,stop,no,n,cancel,quit,exit,nothing,none') \
        || stop_cleanly "No choice was made about the image already on this USB drive, so it was left alone."

    case "$_act" in
    additional)
        # Space is not estimated from a model. It is measured against the image
        # already on this drive, which came off this same unit and is the closest
        # reference that exists.
        if [ -n "${_szb:-}" ] && [ -n "${_freeb:-}" ] \
           && [ "$_freeb" -lt "$_szb" ] 2>/dev/null; then
            echo ""
            echo " There is not enough room on this USB drive for a second image."
            echo " The one already here is ${_sz:-unknown} and only ${_free:-unknown} is free,"
            echo " and a second capture of this unit would be about the same size."
            echo ""
            if ask_yes_no ' Replace the existing image instead? (yes/no): '; then
                _act=replace
            else
                stop_cleanly "Nothing was captured. Use a larger USB drive to hold two images."
            fi
        fi
        ;;
    esac

    if [ "$_act" = additional ]; then
        # Suggest the next free suffix, so Enter is a complete answer.
        _sfx=2
        while [ -d "$MEDIUM/home/partimag/${IMAGE_NAME}-${_sfx}" ]; do
            _sfx=$((_sfx + 1))
        done
        _suggest="${IMAGE_NAME}-${_sfx}"
        _newname=""
        _nt=0
        while [ -z "$_newname" ] && [ "$_nt" -lt 3 ]; do
            _nt=$((_nt + 1))
            echo ""
            echo " The new image needs its own name. Press Enter to accept the"
            echo " suggestion, or type a different one."
            _nn=$(ask_line " Name for the additional image [$_suggest]: ") \
                || stop_cleanly "No name could be read for the additional image."
            # Sanitized on the way in, exactly like the bench answers, because
            # this becomes a directory name on a FAT32 stick.
            _nn=$(sanitize "$_nn" 60)
            [ -n "$_nn" ] && [ "$_nn" != "$IMAGE_NAME" ] || _nn="$_suggest"
            if [ -d "$MEDIUM/home/partimag/$_nn" ]; then
                echo " There is already an image called '$_nn' on this drive."
                continue
            fi
            _newname="$_nn"
        done
        [ -n "$_newname" ] || stop_cleanly "No usable name was given for the additional image, so nothing was captured."
        IMAGE_NAME="$_newname"
        echo ""
        echo " Keeping   : $(basename "$EXISTING") (${_sz:-unknown})"
        echo " Capturing : $IMAGE_NAME"
        mount -o remount,rw "$MEDIUM" 2>/dev/null
        {
          echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) additional capture as $IMAGE_NAME, kept $(basename "$EXISTING") (${_sz:-unknown})"
        } >> "$MEDIUM/TOAST/logs/capture.log" 2>/dev/null
        # capture.done is deliberately NOT removed here. It still describes an
        # image that is still on the drive, and ocs-capture.sh rewrites it with
        # the new name once this capture finishes.
    fi

    if [ "$_act" = replace ]; then
        mount -o remount,rw "$MEDIUM" 2>/dev/null
        # Removed only after the answer, and only this one directory by name.
        if rm -rf "$EXISTING" 2>/dev/null; then
            echo "TOAST: replaced - removed the previous $IMAGE_NAME"
            {
              echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) replaced existing image $IMAGE_NAME (${_sz:-unknown}, created $_when)"
            } >> "$MEDIUM/TOAST/logs/capture.log" 2>/dev/null
            # The completion marker refers to the image that has just been deleted.
            rm -f "$MEDIUM/TOAST/config/capture.done" 2>/dev/null
            sync
        else
            fail "Could not remove the previous image '$IMAGE_NAME' from the USB drive."
        fi
    fi

    if [ "$_act" = stop ]; then
        stop_cleanly "The image '$IMAGE_NAME' already on this USB drive was kept."
    fi
fi

# Own the image repository mount explicitly. The medium is our own FAT32
# partition, so bind-mount its home/partimag rather than letting ocs_repository
# mount the boot device a second time.
mount -o remount,rw "$MEDIUM" 2>/dev/null || true
mkdir -p "$MEDIUM/home/partimag" /home/partimag 2>/dev/null || true
mount --bind "$MEDIUM/home/partimag" /home/partimag || fail "Could not prepare the image folder on the USB."

echo "$TARGET"     > /tmp/toast_target
echo "$IMAGE_NAME" > /tmp/toast_image
echo "TOAST: target /dev/$TARGET (resolved by $RESOLVED_BY), image $IMAGE_NAME"
exit 0
