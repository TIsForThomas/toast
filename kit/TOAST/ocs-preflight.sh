#!/bin/sh
# TOAST Image Capture Kit - work out whether an image can be restored onto a disk.
#
# Split out of ocs-deploy.sh so the arithmetic is testable on its own, against a
# real image directory, with no unit and no interactive session. This is the
# calculation that decides whether a customer's disk gets overwritten, so it
# should not only be reachable through a menu.
#
# Usage:  ocs-preflight.sh <image-dir> [target-bytes]
# Prints KEY=VALUE lines. With target-bytes: exit 0 if it fits, 1 if it does not.
#
# WHY THIS IS NEEDED AT ALL
# Clonezilla will not refuse a too-small GPT target: ocs-expand-gpt-pt sets
# chk_tgt_disk_size_bf_mk_pt and then never tests it, so -k1 builds a smaller
# partition table and lets the restore die inside partclone twenty minutes later.
set -u

SECTOR=512
IMGDIR="${1:?image directory required}"
TARGET_BYTES="${2:-}"

[ -d "$IMGDIR" ] || { echo "ERROR=no such image directory: $IMGDIR"; exit 2; }
SRCDISK=$(cat "$IMGDIR/disk" 2>/dev/null | tr -d ' \r\n')
[ -n "$SRCDISK" ] || { echo "ERROR=image records no source disk (missing 'disk' file)"; exit 2; }
PTSF="$IMGDIR/${SRCDISK}-pt.sf"
[ -r "$PTSF" ] || { echo "ERROR=image has no partition table (${SRCDISK}-pt.sf)"; exit 2; }

# ⛔ THE FIXED SET IS THE FOUR TYPES, AND EVERYTHING ELSE SCALES. Read that way
# round from Clonezilla's own ocs-expand-gpt-pt, which tests
#   C12A7328 (ESP) | E3C9E316 (MSR) | DE94BBA4 (Recovery) | 0657FD6D (swap)
# and scales anything that does not match.
#
# This was inverted here: only EBD0A0A2 (Windows Basic data) was treated as
# scalable and everything else as fixed. On a LINUX disk the root partition is
# 0FC63DAF, so it counted as a fixed cost, no scalable partition was found, and
# the pre-flight aborted with "no Basic-data (Windows) partition found". The kit
# deploys Linux images too. Fixed 2026-09-05.
FIXED_TYPES='C12A7328|E3C9E316|DE94BBA4|0657FD6D'
FIXED_SECTORS=$(awk -F'[=,]' '
    /^\/dev\// {
        size = 0; type = ""
        for (i = 1; i <= NF; i++) {
            if ($i ~ /size$/) { size = $(i+1) + 0 }
            if ($i ~ /type$/) { type = $(i+1) }
        }
        gsub(/[ \t]/, "", type)
        if (type ~ /^(C12A7328|E3C9E316|DE94BBA4|0657FD6D)/) fixed += size
    }
    END { printf "%d", fixed + 0 }' "$PTSF")

FIRST_START=$(awk -F'[=,]' '/^\/dev\// { for (i=1;i<=NF;i++) if ($i ~ /start$/) { print $(i+1)+0; exit } }' "$PTSF")
: "${FIRST_START:=2048}"

# FIRST_START covers the primary GPT header and table at the front; the backup
# GPT costs 33 sectors at the end. That is the whole geometric overhead.
#
# ⛔ Do NOT add flat alignment slack here. A 1 MiB pad was tried and it falsely
# refused a 1:1 restore of an image back onto its OWN original disk, by 709 KB:
# the captured filesystem is already slightly smaller than its partition, so an
# exact fit has only a few hundred KB of headroom and a megabyte of pad wipes it
# out. Alignment loss on the target is absorbed by the shrink margin
# (minimum + 15%, floored at 3 GiB) that the capture already leaves in the
# Basic-data partition. Real refusals are unaffected: the real too-small case is short by
# 768 GB, not by kilobytes. Found by testing against the real image, 2026-09-04.
OVERHEAD_SECTORS=$((FIRST_START + 33))

NEED_FS=0
NEED_USED=0
NPARTS=0
for pimg in "$IMGDIR"/*-ptcl-img.*; do
    [ -f "$pimg" ] || continue
    base=$(basename "$pimg")
    case "$base" in *.aa) : ;; *) continue ;; esac        # first split volume only
    part=$(echo "$base" | sed 's/\..*//')
    ptype=$(awk -F'[=,]' -v p="/dev/$part" '$0 ~ "^"p" " { for (i=1;i<=NF;i++) if ($i ~ /type$/) { t=$(i+1); gsub(/[ \t]/,"",t); print t; exit } }' "$PTSF")
    # Skip only the partitions -k1 will hold at their original size.
    case "$ptype" in C12A7328*|E3C9E316*|DE94BBA4*|0657FD6D*) continue ;; esac

    case "$base" in
        *.gz.aa)  dec="gzip -dc" ;;
        *.zst.aa) dec="zstd -dc" ;;
        *.xz.aa)  dec="xz -dc"   ;;
        *.lzo.aa) dec="lzop -dc" ;;
        *.lz4.aa) dec="lz4 -dc"  ;;
        *)        dec="cat"      ;;
    esac

    # Capture into a variable, then match on it. Piping into `grep -q` would
    # SIGPIPE the decompressor and, under pipefail, a SUCCESSFUL match would read
    # as a failure. Same trap as the touch checks in workflow.sh.
    hdr=$(head -c 4000000 "$pimg" 2>/dev/null | $dec 2>/dev/null | ${PARTCLONE_INFO:-partclone.info} -L /tmp/pc-preflight.log -s - 2>&1)
    blocks=$(echo "$hdr" | sed -n 's/^Device size:.*= *\([0-9]\+\) Blocks.*/\1/p' | head -1)
    bsize=$(echo  "$hdr" | sed -n 's/^Block size: *\([0-9]\+\) Byte.*/\1/p'      | head -1)
    used=$(echo   "$hdr" | sed -n 's/^Space in use:.*= *\([0-9]\+\) Blocks.*/\1/p' | head -1)
    if [ -z "$blocks" ] || [ -z "$bsize" ]; then
        echo "ERROR=could not read the partclone header for $part (image may be damaged or incomplete)"
        exit 2
    fi
    NEED_FS=$((NEED_FS + blocks * bsize))
    NEED_USED=$((NEED_USED + ${used:-0} * bsize))
    NPARTS=$((NPARTS + 1))
    echo "PART_${part}_FS_BYTES=$((blocks * bsize))"
    echo "PART_${part}_USED_BYTES=$((${used:-0} * bsize))"
done

[ "$NPARTS" -gt 0 ] || { echo "ERROR=no resizable operating-system partition found in the image"; exit 2; }

FIXED_BYTES=$(( (FIXED_SECTORS + OVERHEAD_SECTORS) * SECTOR ))
REQUIRED=$((FIXED_BYTES + NEED_FS))

echo "SOURCE_DISK=$SRCDISK"
echo "DATA_PARTS=$NPARTS"
echo "FIXED_SECTORS=$FIXED_SECTORS"
echo "OVERHEAD_SECTORS=$OVERHEAD_SECTORS"
echo "FIXED_BYTES=$FIXED_BYTES"
echo "WINDOWS_FS_BYTES=$NEED_FS"
echo "WINDOWS_USED_BYTES=$NEED_USED"
echo "REQUIRED_BYTES=$REQUIRED"

if [ -n "$TARGET_BYTES" ]; then
    echo "TARGET_BYTES=$TARGET_BYTES"
    if [ "$TARGET_BYTES" -lt "$REQUIRED" ]; then
        echo "SHORT_BY_BYTES=$((REQUIRED - TARGET_BYTES))"
        echo "FITS=no"
        exit 1
    fi
    spare=$((TARGET_BYTES - REQUIRED))
    echo "SPARE_BYTES=$spare"
    echo "FITS=yes"
    # It fits, but by so little that target-side partition alignment could still
    # eat the difference. Say so rather than refusing: this is what a same-size
    # 1:1 restore legitimately looks like.
    [ "$spare" -lt 1048576 ] && echo "WARN=fits with only ${spare} bytes spare; alignment on the target could still be tight"
fi
exit 0
