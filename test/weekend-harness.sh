#!/bin/bash
# TOAST unattended evidence harness. Runs for hours or days without a session.
#
#   sudo systemd-run --unit=toast-harness --collect \
#        nice -n 15 ionice -c3 /path/weekend-harness.sh
#
# ⛔ IT CHANGES NOTHING. It never edits a kit script, never builds an ISO, never
# publishes. Decided explicitly: an unattended run cannot verify a fix it
# invented, so it gathers evidence and stops. Enforced below by recording a
# checksum of every kit script at the start and re-checking at the end.
#
# WHY A FILMSTRIP RATHER THAN TIMED SHOTS
# Screenshotting "at the moment the prompt appears" needs the timing to be right
# every run, and QEMU boot timing is not repeatable. So it screenshots on a fixed
# cadence throughout each case. The frames that matter can be picked afterwards,
# and a missed prompt costs one frame rather than the whole case.
#
# RESOURCES: one guest at a time, 2 vCPU, 2 GB, niced and idle-I/O. Refuses to
# start a case if free RAM or its own byte budget says no.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$HERE/../kit/TOAST"
OUT_ROOT=${OUT_ROOT:-$HERE/weekend-runs}
RUN="$OUT_ROOT/$(date +%Y%m%d-%H%M%S)"
ISO=${ISO:-$(ls -1t "$HERE"/TOAST-*.iso 2>/dev/null | head -1)}

BUDGET_GB=${BUDGET_GB:-150}        # total this harness may leave on disk
MIN_FREE_GB=${MIN_FREE_GB:-300}    # backstop: don't start on a struggling array
MIN_FREE_RAM_GB=${MIN_FREE_RAM_GB:-6}
SHOT_EVERY=${SHOT_EVERY:-8}        # seconds between filmstrip frames
MAX_ROUNDS=${MAX_ROUNDS:-0}        # 0 = until stopped

mkdir -p "$RUN"
SUM="$RUN/HARNESS.log"
say() { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$SUM"; }

# ---------------------------------------------------------------- guards
guard() {
    local free_gb ram_gb used_gb
    free_gb=$(df -BG --output=avail "$OUT_ROOT" | tail -1 | tr -dc '0-9')
    ram_gb=$(free -g | awk '/^Mem:/{print $7}')
    used_gb=$(du -sBG "$OUT_ROOT" 2>/dev/null | cut -f1 | tr -dc '0-9')
    [ "${free_gb:-0}" -ge "$MIN_FREE_GB" ] || { say "STOP: array free ${free_gb}GB < ${MIN_FREE_GB}GB"; return 1; }
    [ "${ram_gb:-0}" -ge "$MIN_FREE_RAM_GB" ] || { say "PAUSE: only ${ram_gb}GB RAM available"; return 2; }
    [ "${used_gb:-0}" -lt "$BUDGET_GB" ] || { say "STOP: harness has used ${used_gb}GB of its ${BUDGET_GB}GB budget"; return 1; }
    return 0
}

# ---------------------------------------------------------------- fixtures
# A synthetic Windows disk: the canonical 4-partition UEFI layout with Recovery
# LAST, which is the layout the deploy-side rescale has to cope with.
make_windows_disk() {  # path, size, used_mb
    local img=$1 size=$2 used=$3
    rm -f "$img"; truncate -s "$size" "$img"
    sgdisk -og "$img" >/dev/null 2>&1
    sgdisk -n 1:2048:+260M  -t 1:ef00 -c 1:"EFI system partition" "$img" >/dev/null 2>&1
    sgdisk -n 2:0:+16M      -t 2:0c01 -c 2:"Microsoft reserved"   "$img" >/dev/null 2>&1
    sgdisk -n 3:0:-1025M    -t 3:0700 -c 3:"Basic data partition" "$img" >/dev/null 2>&1
    sgdisk -n 4:0:0         -t 4:2700 -c 4:"Recovery"             "$img" >/dev/null 2>&1

    local lo; lo=$(losetup --show -f -P "$img") || { say "FIXTURE: losetup failed"; return 1; }

    # ⛔ WAIT FOR THE PARTITION NODES. losetup -P asks the kernel to scan, but
    # the /dev/loopNpN nodes appear via udev a moment later. Without this the
    # mkntfs and the mount below race and fail, and the FIRST version of this
    # function swallowed those failures and returned success anyway. The result
    # was a fixture with no \Windows\System32 on it, and the harness then
    # reported "could not identify exactly one disk with Windows on it" as
    # though TOAST were broken. The discovery logic was fine; the fixture was
    # not. A harness that invents product failures is worse than no harness.
    udevadm settle 2>/dev/null
    local w=0
    while [ ! -b "${lo}p3" ] && [ "$w" -lt 50 ]; do sleep 0.2; w=$((w+1)); done
    for pn in 1 3 4; do
        [ -b "${lo}p${pn}" ] || { say "FIXTURE: ${lo}p${pn} never appeared"; losetup -d "$lo"; return 1; }
    done

    mkfs.vfat -F32 "${lo}p1" >/dev/null 2>&1 || { say "FIXTURE: ESP mkfs failed"; losetup -d "$lo"; return 1; }
    mkntfs -Q -F -L Windows  "${lo}p3" >/dev/null 2>&1 || { say "FIXTURE: p3 mkntfs failed"; losetup -d "$lo"; return 1; }
    mkntfs -Q -F -L Recovery "${lo}p4" >/dev/null 2>&1 || { say "FIXTURE: p4 mkntfs failed"; losetup -d "$lo"; return 1; }

    local m; m=$(mktemp -d)
    if ! mount -t ntfs-3g "${lo}p3" "$m" 2>/dev/null; then
        say "FIXTURE: could not mount ${lo}p3 to populate it"
        rmdir "$m"; losetup -d "$lo"; return 1
    fi
    mkdir -p "$m/Windows/System32/config" "$m/Users" "$m/Program Files"
    echo synthetic > "$m/Windows/System32/config/SYSTEM"
    # Used space, mostly compressible like a real install. Kept modest on
    # purpose: this goes through ntfs-3g, which is FUSE, and 6 GB took minutes.
    head -c $((used * 1024 * 1024)) /dev/zero > "$m/bulk.dat" 2>/dev/null
    head -c $((used * 32 * 1024)) /dev/urandom >> "$m/bulk.dat" 2>/dev/null
    sync
    umount "$m"

    # Prove the fixture is what we think it is before handing it to a case.
    if mount -t ntfs-3g -o ro "${lo}p3" "$m" 2>/dev/null; then
        if [ ! -d "$m/Windows/System32" ]; then
            say "FIXTURE: verification failed, no Windows/System32 on ${lo}p3"
            umount "$m"; rmdir "$m"; losetup -d "$lo"; return 1
        fi
        umount "$m"
    else
        say "FIXTURE: verification remount failed"
        rmdir "$m"; losetup -d "$lo"; return 1
    fi
    rmdir "$m"; losetup -d "$lo"
    say "fixture verified: 4-partition GPT, Windows on p3, ${used}MB used"
    return 0
}

# A writable kit stick, so the scripts' own logs land somewhere we can read.
make_stick() {  # path
    local img=$1
    rm -f "$img"
    ( cd "$HERE" && ./write-kit --image "$img" --size 40G --yes ) >>"$SUM" 2>&1
}

# ---------------------------------------------------------------- one case
# run_case <name> <timeout> <keyscript> <extra qemu args...>
# keyscript: lines of "<seconds> <qmp keys...>", sent at that offset.
run_case() {
    local name=$1 tmo=$2 keys=$3; shift 3
    local dir="$RUN/$name"; mkdir -p "$dir/frames"
    local sock=/tmp/toast-h-$$-$name.sock
    rm -f "$sock"
    cp -f /usr/share/OVMF/OVMF_VARS_4M.fd "$dir/ovmf.fd"

    say "CASE $name starting (timeout ${tmo}s)"
    nice -n 15 ionice -c3 qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 \
        -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
        -drive if=pflash,format=raw,unit=1,file="$dir/ovmf.fd" \
        -device qemu-xhci,id=xhci -device usb-kbd \
        "$@" \
        -serial "file:$dir/serial.log" -display none \
        -qmp "unix:$sock,server,nowait" -no-reboot >>"$dir/qemu.log" 2>&1 &
    local q=$!
    local t=0 frame=0 lastkept=""
    while [ "$t" -lt "$tmo" ]; do
        kill -0 $q 2>/dev/null || { say "  guest exited at ${t}s"; break; }
        sleep "$SHOT_EVERY"; t=$((t + SHOT_EVERY)); frame=$((frame + 1))
        # ⛔ Convert and DEDUPLICATE immediately, do not accumulate PPMs.
        # A screen that is not changing produced 100 near-identical 3 MB frames in
        # ten minutes on the first run. Over a weekend that is tens of thousands
        # of useless files, and a guide needs the handful of frames where
        # something actually happened. So: shoot, convert, compare against the
        # last KEPT frame, and throw it away if nothing moved.
        local raw="$dir/.shot.ppm"
        rm -f "$raw"
        printf '{"execute":"qmp_capabilities"}\n{"execute":"screendump","arguments":{"filename":"%s"}}\n' \
            "$raw" | timeout 15 socat - "UNIX-CONNECT:$sock" >/dev/null 2>&1
        if [ -s "$raw" ]; then
            local png="$dir/frames/$(printf '%03d' $frame)-t${t}s.png"
            if convert "$raw" "$png" 2>/dev/null; then
                if [ -n "${lastkept:-}" ] && [ -f "$lastkept" ]; then
                    # AE = count of differing pixels. A cursor blink is a few
                    # hundred; a new line of text is thousands.
                    # compare emits scientific notation for large values
                    # ("1.024e+06", which it also does when the two images are
                    # DIFFERENT SIZES, i.e. every resolution change during boot).
                    # Stripping non-digits turned that into 102406, a mangled
                    # number that only happened to stay above the threshold.
                    local diff
                    diff=$(compare -metric AE "$png" "$lastkept" null: 2>&1 \
                           | awk '{printf "%d", ($1+0)}' 2>/dev/null)
                    if [ "${diff:-999999}" -lt "${FRAME_MIN_DIFF:-400}" ]; then
                        rm -f "$png"
                    else
                        lastkept="$png"
                        printf '%s\t%s\t%s\n' "$t" "$(basename "$png")" "$diff" >>"$dir/frames.tsv"
                    fi
                else
                    lastkept="$png"
                    printf '%s\t%s\t%s\n' "$t" "$(basename "$png")" "first" >>"$dir/frames.tsv"
                fi
            fi
            rm -f "$raw"
        fi
        # Any keystrokes scheduled for this moment.
        if [ -r "$keys" ]; then
            awk -v now="$t" -v prev="$((t - SHOT_EVERY))" '$1 > prev && $1 <= now {$1=""; print}' "$keys" \
            | while IFS= read -r k; do
                [ -n "$k" ] || continue
                say "  sending keys at ${t}s: $k"
                for kk in $k; do
                    printf '{"execute":"qmp_capabilities"}\n{"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"%s"}]}}\n' "$kk" \
                        | timeout 10 socat - "UNIX-CONNECT:$sock" >/dev/null 2>&1
                    sleep 0.15
                done
              done
        fi
    done
    kill $q 2>/dev/null; wait $q 2>/dev/null
    rm -f "$sock"

    rm -f "$dir/.shot.ppm"
    local n; n=$(ls -1 "$dir/frames"/*.png 2>/dev/null | wc -l)
    say "CASE $name done, $n frames kept of $frame taken ($(du -sh "$dir" 2>/dev/null | cut -f1))"
}

# Read the scripts' own logs back off the stick after a case.
harvest_stick() {  # stickimg, dest
    local img=$1 dest=$2 lo m
    mkdir -p "$dest"
    lo=$(losetup --show -f -P "$img" 2>/dev/null) || return 0
    m=$(mktemp -d)
    if mount -o ro "${lo}p1" "$m" 2>/dev/null; then
        cp -r "$m/TOAST/logs" "$dest/logs" 2>/dev/null
        cp -r "$m/TOAST/config" "$dest/config" 2>/dev/null
        ls -laR "$m/home/partimag" > "$dest/partimag-listing.txt" 2>/dev/null
        du -sh "$m/home/partimag"/* > "$dest/partimag-sizes.txt" 2>/dev/null
        umount "$m"
    fi
    rmdir "$m"; losetup -d "$lo"
}

# ---------------------------------------------------------------- integrity
# Prove afterwards that nothing in the kit was touched.
fingerprint() { (cd "$KIT" && sha256sum ocs-*.sh KIT-VERSION.txt START-HERE.md 2>/dev/null | sort); }
fingerprint > "$RUN/kit-before.sha256"

say "TOAST weekend harness"
say "ISO      $(basename "${ISO:-none}")"
say "output   $RUN"
say "budget   ${BUDGET_GB}GB   cadence ${SHOT_EVERY}s"
[ -n "${ISO:-}" ] && [ -r "$ISO" ] || { say "FATAL: no ISO found"; exit 1; }
guard || { say "FATAL: guards refused at start"; exit 1; }

# ---------------------------------------------------------------- the cases
round=0
while :; do
    round=$((round + 1))
    [ "$MAX_ROUNDS" -gt 0 ] && [ "$round" -gt "$MAX_ROUNDS" ] && { say "reached MAX_ROUNDS"; break; }
    say "===== round $round ====="

    g=0; guard || g=$?
    if [ "$g" = 1 ]; then break; fi
    if [ "$g" = 2 ]; then say "sleeping 15m for RAM"; sleep 900; continue; fi

    W="$RUN/fixtures/win-$round.img"; S="$RUN/fixtures/stick-$round.img"
    T="$RUN/fixtures/target-$round.img"
    mkdir -p "$RUN/fixtures"

    say "building fixtures"
    make_windows_disk "$W" 40G 2000 || { say "fixture build failed"; break; }
    make_stick "$S" || { say "stick build failed"; break; }
    rm -f "$T"; truncate -s 30G "$T"

    # 1. The menu, both firmware paths. Pure screenshots for the guide.
    # Menu, then boot it, so the guide gets both the menu and what follows.
    printf '30 ret\n' > "$RUN/keys-menu"
    run_case "01-menu-uefi" 90 "$RUN/keys-menu" \
        -drive if=none,id=cd,file="$ISO",format=raw,media=cdrom -device ide-cd,drive=cd,bootindex=0

    # THE FIRST KEYSTROKE IS ALWAYS "ret" TO LEAVE THE MENU. From TOAST 1.7 the
    # menu has no countdown and waits for a keypress, so a schedule written for
    # the old auto-boot sits at the menu forever. The first smoke run did exactly
    # that: one frame kept across three minutes, because nothing on screen ever
    # changed. Entries below the first need "down" to move the highlight.
    #
    # 2. Capture from a stick, bench prompts. Company "acme", Enter for v1, yes.
    cat > "$RUN/keys-capture" <<'EOK'
12 ret
150 a c m e ret
168 ret
186 y ret
204 y ret
EOK
    run_case "02-capture-bench" 900 "$RUN/keys-capture" \
        -drive if=none,id=kit,file="$S",format=raw -device usb-storage,bus=xhci.0,drive=kit,bootindex=0 \
        -drive if=none,id=win,file="$W",format=raw -device ide-hd,drive=win,serial=TOASTSRC1
    harvest_stick "$S" "$RUN/02-capture-bench/stick"

    # 3. Deploy onto a disk too small: the pre-flight must refuse before writing.
    # Deploy is the SECOND entry: move the highlight down once first.
    cat > "$RUN/keys-deploy-small" <<'EOK'
12 down ret
150 1 ret
168 1 ret
EOK
    run_case "03-deploy-refuses-small" 420 "$RUN/keys-deploy-small" \
        -drive if=none,id=kit,file="$S",format=raw -device usb-storage,bus=xhci.0,drive=kit,bootindex=0 \
        -drive if=none,id=tgt,file="$T",format=raw -device ide-hd,drive=tgt,serial=TOASTTGT1
    harvest_stick "$S" "$RUN/03-deploy-refuses-small/stick"

    # 4. The repair entry on an untouched disk: must be a clean no-op.
    # Repair is the THIRD entry.
    cat > "$RUN/keys-repair" <<'EOK'
12 down down ret
180 ret
EOK
    run_case "04-repair-noop" 300 "$RUN/keys-repair" \
        -drive if=none,id=kit,file="$S",format=raw -device usb-storage,bus=xhci.0,drive=kit,bootindex=0 \
        -drive if=none,id=win,file="$W",format=raw -device ide-hd,drive=win,serial=TOASTSRC1
    harvest_stick "$S" "$RUN/04-repair-noop/stick"

    # Keep the fixtures if any case failed to produce its logs: without them a
    # failure cannot be diagnosed afterwards, which is the whole point of an
    # unattended run. The first smoke run deleted them and the diagnosis had to
    # be redone by hand on the server.
    local kept=no
    for c in 02-capture-bench 03-deploy-refuses-small 04-repair-noop; do
        [ -d "$RUN/$c/stick/logs" ] || kept=yes
    done
    if [ "$kept" = yes ]; then
        say "a case produced no logs: KEEPING fixtures for diagnosis"
        mkdir -p "$RUN/fixtures-kept"
        mv -f "$W" "$S" "$T" "$RUN/fixtures-kept/" 2>/dev/null
    else
        rm -f "$W" "$S" "$T"
    fi
    say "round $round complete, $(du -sh "$RUN" | cut -f1) on disk"
done

fingerprint > "$RUN/kit-after.sha256"
if diff -q "$RUN/kit-before.sha256" "$RUN/kit-after.sha256" >/dev/null; then
    say "INTEGRITY OK: no kit script was modified"
else
    say "INTEGRITY WARNING: kit scripts differ, see kit-before/after.sha256"
fi

{
    echo "# TOAST weekend harness run"
    echo
    echo "ISO: $(basename "$ISO")"
    echo "Started: $(head -1 "$SUM" | awk '{print $1}')   Finished: $(date +%H:%M:%S)"
    echo "Rounds completed: $((round - 1))"
    echo "Disk used: $(du -sh "$RUN" | cut -f1)"
    echo
    echo "## Frames per case"
    for d in "$RUN"/[0-9]*; do
        [ -d "$d" ] || continue
        printf -- '- %s: %s frames\n' "$(basename "$d")" "$(ls -1 "$d/frames"/*.png 2>/dev/null | wc -l)"
    done
    echo
    echo "## What to look at first"
    echo "- Each case's frames/ is a filmstrip; pick the frames that show a prompt."
    echo "- Each case's stick/logs/ holds the scripts' own shrink.log and capture.log."
    echo "- serial.log is the kernel and live-boot console, not the script output."
    echo
    echo "This harness changes nothing. kit-before.sha256 and kit-after.sha256 prove it."
} > "$RUN/FINDINGS.md"

say "wrote $RUN/FINDINGS.md"
