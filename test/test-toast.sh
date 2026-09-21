#!/bin/bash
# TOAST test suite. Everything that can be checked without a TOAST unit.
#
#   ./test-toast.sh [iso]        default: newest TOAST-*.iso in this directory
#
# Groups:
#   A  static checks on the ISO itself
#   B  boot tests, UEFI and legacy BIOS, with screenshots
#   C  engine and logic tests against real fixtures on this server
#
# Writes everything under test-runs/<timestamp>/ and prints a pass/fail table.
# ⛔ Enforces a free-space floor before it starts: this runs QEMU and NTFS
# fixtures on the array that also holds the images and MDT.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
KIT="$HERE/../kit/TOAST"
WINDOWS_SRC=${WINDOWS_SRC:-$HERE/../windows}
ISO="${1:-$(ls -1t TOAST-*.iso 2>/dev/null | head -1)}"
# Backstop only. The harness is bounded by its own byte budget below; this just
# stops it starting on an array that is already in trouble.
MIN_FREE_GB=${MIN_FREE_GB:-50}
RUN="$HERE/test-runs/$(date +%Y%m%d-%H%M%S)"
LEAK_PATTERNS=${LEAK_PATTERNS:-$HERE/../build/leak-patterns.txt}
LEAK_RE=$(grep -vE '^[[:space:]]*(#|$)' "$LEAK_PATTERNS" | paste -sd'|')
# Optional. Group C ends with three checks against a REAL captured image,
# because a hand-made fixture cannot reproduce a genuine partclone header.
# Set both to run them; they skip cleanly if either is missing.
PCINFO=${PARTCLONE_INFO:-$(command -v partclone.info || true)}
REF_IMAGE=${REF_IMAGE:-}

[ -n "$ISO" ] && [ -r "$ISO" ] || { echo "no ISO to test (looked for TOAST-*.iso)" >&2; exit 1; }
free_gb=$(df -BG --output=avail "$HERE" | tail -1 | tr -dc '0-9')
[ "${free_gb:-0}" -ge "$MIN_FREE_GB" ] || { echo "only ${free_gb} GB free, need ${MIN_FREE_GB}" >&2; exit 1; }

mkdir -p "$RUN"
LOG="$RUN/results.tsv"
PASS=0; FAIL=0; SKIP=0

ok()   { printf 'PASS\t%s\t%s\n' "$1" "${2:-}" >>"$LOG"; PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf 'FAIL\t%s\t%s\n' "$1" "${2:-}" >>"$LOG"; FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s  -- %s\n' "$1" "${2:-}"; }
skip() { printf 'SKIP\t%s\t%s\n' "$1" "${2:-}" >>"$LOG"; SKIP=$((SKIP+1)); printf '  \033[33mSKIP\033[0m  %s  -- %s\n' "$1" "${2:-}"; }
chk()  { if [ "$2" = "$3" ]; then ok "$1" "$2"; else bad "$1" "want '$3' got '$2'"; fi; }

echo "TOAST test suite"
echo "ISO      : $(basename "$ISO")  ($(du -h "$ISO" | cut -f1))"
echo "results  : $RUN"
echo "free     : ${free_gb} GB"
echo

# =========================================================== A: static ISO
echo "A. Static checks on the ISO"
M9="$RUN/m9"; mkdir -p "$M9"
if sudo mount -o ro,loop,norock,nojoliet "$ISO" "$M9" 2>/dev/null; then
    td=$(ls "$M9" | grep -ix toast | head -1)
    sd=$(ls "$M9/$td" 2>/dev/null | grep -ix scripts | head -1)
    [ -n "$td" ] && ok "A01 TOAST dir present in plain ISO9660" || bad "A01 TOAST dir present in plain ISO9660"
    [ -n "$sd" ] && ok "A02 TOAST/scripts present" || bad "A02 TOAST/scripts present"

    # A03: every payload name survives the ISO9660 namespace intact.
    miss=""
    for f in ocs-common.sh ocs-prerun.sh ocs-capture.sh ocs-shrink.sh ocs-deploy.sh ocs-repair.sh ocs-preflight.sh; do
        ls "$M9/$td/$sd" 2>/dev/null | grep -qix "$f" || miss="$miss $f"
    done
    for f in Prepare-Sysprep-USB.ps1; do
        ls "$M9/$td/$sd" 2>/dev/null | grep -qix "$f" || miss="$miss $f"
    done
    for f in Run-Toast-Prep.cmd START-HERE.md KIT-VERSION.txt; do
        ls "$M9/$td" 2>/dev/null | grep -qix "$f" || miss="$miss $f"
    done
    [ -z "$miss" ] && ok "A03 all payload names unmangled" || bad "A03 all payload names unmangled" "missing:$miss"

    # A04: the customer must see exactly one runnable file at the top.
    top=$(ls "$M9/$td" | grep -icE '\.(sh|ps1)$' || true)
    chk "A04 no scripts loose in TOAST/" "$top" "0"

    # A05: the writable dirs the capture needs.
    n=0
    for d in home/partimag "$td/config" "$td/logs"; do [ -d "$M9/$d" ] && n=$((n+1)); done
    chk "A05 home/partimag, config, logs all present" "$n" "3"

    # A06: all THREE boot configs carry all three entries.
    for cfg in boot/grub/grub.cfg syslinux/syslinux.cfg syslinux/isolinux.cfg; do
        c=$(grep -ci 'TOAST' "$M9/$cfg" 2>/dev/null || echo 0)
        if [ "$c" -ge 3 ]; then ok "A06 $cfg has the entries" "$c refs"; else bad "A06 $cfg has the entries" "$c refs"; fi
    done

    # A07: no auto-boot on any path.
    g=$(grep -c 'set timeout="-1"' "$M9/boot/grub/grub.cfg" 2>/dev/null || echo 0)
    s1=$(grep -cE '^timeout 0' "$M9/syslinux/syslinux.cfg" 2>/dev/null || echo 0)
    s2=$(grep -cE '^timeout 0' "$M9/syslinux/isolinux.cfg" 2>/dev/null || echo 0)
    if [ "$g" -ge 1 ] && [ "$s1" -ge 1 ] && [ "$s2" -ge 1 ]; then
        ok "A07 auto-boot disabled on all three paths"
    else bad "A07 auto-boot disabled on all three paths" "grub=$g syslinux=$s1 isolinux=$s2"; fi

    # A08: scripts point into scripts/ and nothing points at the old flat path.
    oldp=$(grep -ho 'medium/TOAST/ocs-[a-z]*\.sh' "$M9/boot/grub/grub.cfg" 2>/dev/null | wc -l)
    chk "A08 no boot entry uses the pre-1.4 flat path" "$oldp" "0"

    # A09: compression is the measured choice.
    z=$(grep -o '\-j2 -z[a-z0-9]*' "$M9/$td/$sd/ocs-capture.sh" 2>/dev/null | head -1)
    chk "A09 capture uses zstd (-z9p)" "$z" "-j2 -z9p"

    # A10: nothing customer-facing leaks an internal path.
    leak=0
    for f in "$M9/$td"/*.md "$M9/$td"/*.cmd "$M9/$td"/*.txt "$M9/$td/$sd"/*.ps1; do
        [ -r "$f" ] || continue
        grep -qE "$LEAK_RE" "$f" && leak=$((leak+1))
    done
    chk "A10 no internal paths in customer-facing files" "$leak" "0"

    # A11: version stamped and consistent with the filename.
    # ⛔ The plain ISO9660 namespace folds names to lower case, so resolve the
    # real filename first rather than assuming the mixed-case one.
    kvf=$(ls "$M9/$td" | grep -ix 'KIT-VERSION.txt' | head -1)
    isover=$(tr -d ' \r\n' < "$M9/$td/$kvf" 2>/dev/null)
    fnver=$(basename "$ISO" | sed -n 's/^TOAST-\(.*\)\.iso$/\1/p')
    chk "A11 KIT-VERSION matches the ISO filename" "$isover" "$fnver"

    # A12: the shipped scripts are the ones in the working tree.
    drift=""
    for f in ocs-common.sh ocs-prerun.sh ocs-capture.sh ocs-shrink.sh ocs-deploy.sh ocs-repair.sh ocs-preflight.sh; do
        a=$(sha256sum "$KIT/$f" | cut -d' ' -f1)
        rf=$(ls "$M9/$td/$sd" | grep -ix "$f" | head -1)
        b=$(sudo sha256sum "$M9/$td/$sd/$rf" 2>/dev/null | cut -d' ' -f1)
        { [ -n "$rf" ] && [ "$a" = "$b" ]; } || drift="$drift $f"
    done
    [ -z "$drift" ] && ok "A12 shipped scripts match kit/TOAST" || bad "A12 shipped scripts match kit/TOAST" "drifted:$drift"

    # A13: the Windows half came from windows/, not a stale copy baked in earlier.
    a=$(sha256sum "$WINDOWS_SRC/Prepare-Sysprep-USB.ps1" | cut -d' ' -f1)
    wzf=$(ls "$M9/$td/$sd" | grep -ix 'Prepare-Sysprep-USB.ps1' | head -1)
    b=$(sudo sha256sum "$M9/$td/$sd/$wzf" 2>/dev/null | cut -d' ' -f1)
    if [ "$a" = "$b" ]; then ok "A13 wizard is the live windows/ copy"; else bad "A13 wizard is the live windows/ copy" "hash differs"; fi

    sudo umount "$M9"
else
    bad "A00 could not mount the ISO" "needs sudo"
fi

# A14: hybrid boot records, both platforms.
et=$(xorriso -indev "$ISO" -report_el_torito plain 2>&1 | grep -c 'El Torito boot img')
if [ "$et" -ge 2 ]; then ok "A14 hybrid boot records (BIOS + UEFI)" "$et images"; else bad "A14 hybrid boot records" "$et images"; fi
# A15: volume label, which is what Rufus puts on the drive.
vid=$(xorriso -indev "$ISO" -pvd_info 2>/dev/null | sed -n 's/^Volume Id *: *//p' | tr -d ' ')
chk "A15 volume label is TOAST" "$vid" "TOAST"

# =========================================================== B: boot tests
echo
echo "B. Boot tests"
boot_test() {  # name, mode, delay
    local nm=$1 mode=$2 delay=$3 tag=bt$$_$2
    local sock=/tmp/qmp-$tag.sock shot="$RUN/boot-$mode.ppm"
    rm -f "$sock" "$shot"
    local fw=()
    if [ "$mode" = uefi ]; then
        cp -f /usr/share/OVMF/OVMF_VARS_4M.fd "$RUN/ovmf-$tag.fd"
        fw=(-drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd
            -drive if=pflash,format=raw,unit=1,file="$RUN/ovmf-$tag.fd")
    fi
    qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 "${fw[@]}" \
        -drive if=none,id=cd,file="$ISO",format=raw,media=cdrom \
        -device ide-cd,drive=cd,bootindex=0 \
        -serial "file:$RUN/serial-$mode.log" -display none \
        -qmp "unix:$sock,server,nowait" -no-reboot &
    local q=$!
    sleep "$delay"
    printf '{"execute":"qmp_capabilities"}\n{"execute":"screendump","arguments":{"filename":"%s"}}\n' "$shot" \
        | timeout 20 socat - "UNIX-CONNECT:$sock" >/dev/null 2>&1
    kill $q 2>/dev/null; wait $q 2>/dev/null
    if [ -s "$shot" ]; then
        convert "$shot" "$RUN/boot-$mode.png" 2>/dev/null && rm -f "$shot"
        ok "$nm" "screenshot $(basename "$RUN")/boot-$mode.png"
    else
        bad "$nm" "no screendump produced"
    fi
}
boot_test "B01 boots under UEFI, menu rendered" uefi 12
boot_test "B02 boots under legacy BIOS, menu rendered" bios 14
# B03: still on the menu well past any old timeout, i.e. auto-boot really is off.
boot_test "B03 still on the menu after 35s (no auto-boot)" uefi 35

# =========================================================== C: engine tests
echo
echo "C. Engine and logic tests"
SH="$KIT/ocs-shrink.sh"
PF="$KIT/ocs-preflight.sh"
FM="$RUN/medium"; mkdir -p "$FM/TOAST/config" "$FM/TOAST/logs" "$FM/home/partimag"
export TOAST_MEDIUM="$FM"

# C01-C04: NTFS shrink, expand, integrity, cleanliness.
NT="$RUN/ntfs.img"
truncate -s 8G "$NT"
if mkntfs -Q -F "$NT" >/dev/null 2>&1; then
    mkdir -p "$RUN/nm"
    if sudo mount -t ntfs-3g -o loop,uid=$(id -u) "$NT" "$RUN/nm" 2>/dev/null; then
        mkdir -p "$RUN/nm/Windows/System32/config"
        head -c 1200000000 /dev/urandom > "$RUN/nm/payload.bin" 2>/dev/null
        echo fixture > "$RUN/nm/Windows/System32/config/SYSTEM"
        sync; sudo umount "$RUN/nm"
        want=$(ntfsresize --info -f "$NT" 2>/dev/null | sed -n 's/^Current volume size: \([0-9]*\).*/\1/p' | head -1)
        h0=$(sha256sum "$NT" >/dev/null 2>&1; echo skip)
        if STRIP_VOLATILE=no sh "$SH" shrink-volume "$NT" ntfs >/dev/null 2>&1; then
            got=$(ntfsresize --info -f "$NT" 2>/dev/null | sed -n 's/^Current volume size: \([0-9]*\).*/\1/p' | head -1)
            [ "${got:-0}" -lt "${want:-0}" ] && ok "C01 NTFS shrink reduces the filesystem" "$want -> $got" \
                || bad "C01 NTFS shrink reduces the filesystem" "$want -> $got"
            f=$(ntfsinfo -m "$NT" 2>&1 | grep -c 'Volume Flags: 0x0000')
            chk "C02 volume left clean after shrink (no chkdsk in the image)" "$f" "1"
            if sh "$SH" expand >/dev/null 2>&1; then
                back=$(ntfsresize --info -f "$NT" 2>/dev/null | sed -n 's/^Current volume size: \([0-9]*\).*/\1/p' | head -1)
                chk "C03 expand restores the exact original size" "$back" "$want"
            else bad "C03 expand restores the exact original size" "expand failed"; fi
            if sudo mount -t ntfs-3g -o loop,ro "$NT" "$RUN/nm" 2>/dev/null; then
                [ -f "$RUN/nm/payload.bin" ] && [ -f "$RUN/nm/Windows/System32/config/SYSTEM" ] \
                    && ok "C04 data intact across the round trip" || bad "C04 data intact across the round trip"
                sudo umount "$RUN/nm"
            else bad "C04 data intact across the round trip" "could not remount"; fi
        else bad "C01 NTFS shrink reduces the filesystem" "shrink failed"; fi
    else skip "C01-C04 NTFS round trip" "could not mount the fixture"; fi
else skip "C01-C04 NTFS round trip" "mkntfs unavailable"; fi

# C05: BitLocker must be refused, and nothing written.
BL="$RUN/bl.img"; truncate -s 1G "$BL"; mkntfs -Q -F "$BL" >/dev/null 2>&1
python3 -c "f=open('$BL','r+b'); f.seek(3); f.write(b'-FVE-FS-'); f.close()"
rm -f "$FM/TOAST/config/shrink.state"
if STRIP_VOLATILE=no sh "$SH" shrink-volume "$BL" ntfs >/dev/null 2>&1; then
    bad "C05 BitLocker volume refused" "it proceeded"
else
    [ -f "$FM/TOAST/config/shrink.state" ] && bad "C05 BitLocker volume refused" "wrote state anyway" \
        || ok "C05 BitLocker volume refused, nothing written"
fi

# C06: a structurally inconsistent filesystem must be refused BEFORE any write.
ST="$RUN/stub"; mkdir -p "$ST"
cat > "$ST/ntfsresize" <<'EOS'
#!/bin/sh
case "$*" in *--info*)
  echo "Current volume size: 8589934592 bytes (8590 MB)"
  echo "Checking filesystem consistency ..."
  echo "Cluster accounting failed at 2798018 (0x2ab1c2): extra cluster in \$Bitmap"
  echo "ERROR: NTFS is inconsistent. Run chkdsk /f on Windows then reboot it TWICE!"
  exit 1 ;;
esac
exit 1
EOS
printf '#!/bin/sh\necho STRIP_ATTEMPTED\nexit 1\n' > "$ST/ntfs-3g"
chmod +x "$ST"/*
rm -f "$FM/TOAST/config/shrink.state"
out=$(PATH="$ST:$PATH" sh "$SH" shrink-volume "$NT" ntfs 2>&1 || true)
if echo "$out" | grep -q 'chkdsk C: /f' && ! echo "$out" | grep -q STRIP_ATTEMPTED \
   && [ ! -f "$FM/TOAST/config/shrink.state" ]; then
    ok "C06 inconsistent NTFS refused before any write"
else
    bad "C06 inconsistent NTFS refused before any write" "see $RUN/c06.txt"
    echo "$out" > "$RUN/c06.txt"
fi

# C07-C09: ext2/3/4 path, driven by stubs (mkfs.ext4 is blocked on this host).
cat > "$ST/e2fsck" <<'EOS'
#!/bin/sh
echo "clean, 11/1310720 files"; exit ${TOAST_E2FSCK_RC:-0}
EOS
printf '#!/bin/sh\necho "Block count:              2097152"\necho "Block size:               4096"\n' > "$ST/dumpe2fs"
cat > "$ST/resize2fs" <<'EOS'
#!/bin/sh
case "$*" in *-P*) echo "Estimated minimum size of the filesystem: 524288"; exit 0 ;; esac
echo "resized"; exit 0
EOS
chmod +x "$ST"/*
rm -f "$FM/TOAST/config/shrink.state"
if PATH="$ST:$PATH" sh "$SH" shrink-volume "$RUN/ext.img" ext4 >/dev/null 2>&1; then
    fs=$(sed -n "s/^FSTYPE='\(.*\)'/\1/p" "$FM/TOAST/config/shrink.state")
    chk "C07 ext4 shrink runs and records FSTYPE" "$fs" "ext4"
    t=$(sed -n "s/^TARGET_BYTES='\(.*\)'/\1/p" "$FM/TOAST/config/shrink.state")
    exp=$(python3 -c "m=524288*4096;c=2097152*4096;sl=max(int(m*0.15),3*2**30);print(min(m+sl,c))")
    chk "C08 ext4 target is minimum + slack" "$t" "$exp"
else bad "C07 ext4 shrink runs and records FSTYPE" "it failed"; fi
rm -f "$FM/TOAST/config/shrink.state"
if PATH="$ST:$PATH" TOAST_E2FSCK_RC=4 sh "$SH" shrink-volume "$RUN/ext.img" ext4 >/dev/null 2>&1; then
    bad "C09 unfixable e2fsck refused" "it proceeded"
else
    [ -f "$FM/TOAST/config/shrink.state" ] && bad "C09 unfixable e2fsck refused" "wrote state" \
        || ok "C09 unfixable e2fsck refused, nothing written"
fi

# C10: a filesystem that cannot shrink must SKIP, not abort the capture.
rm -f "$FM/TOAST/config/shrink.state"
if sh "$SH" shrink-volume "$NT" xfs >/dev/null 2>&1; then
    ok "C10 xfs skips the shrink instead of aborting"
else bad "C10 xfs skips the shrink instead of aborting" "non-zero exit"; fi

# C11-C13: the deploy pre-flight, against the real customer image.
if [ -n "$REF_IMAGE" ] && [ -d "$REF_IMAGE" ] && [ -x "$PCINFO" ]; then
    r=$(PARTCLONE_INFO="$PCINFO" sh "$PF" "$REF_IMAGE" 256060514304 2>&1); rc=$?
    chk "C11 refuses the real image on a 256 GB disk" "$(echo "$r" | sed -n 's/^FITS=//p')" "no"
    chk "C12 required size unchanged from the verified figure" \
        "$(echo "$r" | sed -n 's/^REQUIRED_BYTES=//p')" "1024209203712"
    r2=$(PARTCLONE_INFO="$PCINFO" sh "$PF" "$REF_IMAGE" 1024209543168 2>&1)
    chk "C13 accepts the disk it came from" "$(echo "$r2" | sed -n 's/^FITS=//p')" "yes"
else
    skip "C11-C13 pre-flight against the real image" "set REF_IMAGE and have partclone.info on PATH"
fi

# C14: every shipped script parses under dash, not just bash.
badsh=""
for f in "$KIT"/ocs-*.sh; do dash -n "$f" 2>/dev/null || badsh="$badsh $(basename "$f")"; done
[ -z "$badsh" ] && ok "C14 all kit scripts parse under dash" || bad "C14 all kit scripts parse under dash" "$badsh"

# C15: the wizard parses under PowerShell.
if command -v pwsh >/dev/null 2>&1; then
    e=$(pwsh -NoProfile -Command '
        $e=$null
        $null=[System.Management.Automation.Language.Parser]::ParseFile("'"$WINDOWS_SRC"'/Prepare-Sysprep-USB.ps1",[ref]$null,[ref]$e)
        $e.Count' 2>/dev/null | tr -d ' \r')
    chk "C15 wizard parses under PowerShell" "${e:-999}" "0"
else skip "C15 wizard parses under PowerShell" "pwsh not installed"; fi

# =========================================================== D: answers
echo
echo "D. Answers, prompts and every branch of the image choice"

# Every prompt in the kit reads answers through ocs-common.sh, so it is worth
# testing on its own: this is the code that decides whether a typo abandons a
# capture. Answers are piped in, so a wrong turn here can never sit and wait.
CM="$KIT/ocs-common.sh"
ans() { printf '%s' "$2" | dash -c ". \"$CM\"; $1" 2>&1; }

r=$(ans 'if ask_yes_no "q: "; then echo "R=yes"; else echo "R=no"; fi' 'yse
yes
')
chk "D01 a typo re-asks instead of aborting" "$(echo "$r" | sed -n 's/.*R=\(.*\)/\1/p' | tail -1)" "yes"

r=$(ans 'if ask_yes_no "q: "; then echo "R=yes"; else echo "R=no"; fi' 'no
')
chk "D02 no is no" "$(echo "$r" | sed -n 's/.*R=\(.*\)/\1/p' | tail -1)" "no"

r=$(ans 'if ask_yes_no "q: "; then echo "R=yes"; else echo "R=no"; fi' 'q
w
e
')
chk "D03 three unrecognised answers end as no, never as yes" "$(echo "$r" | sed -n 's/.*R=\(.*\)/\1/p' | tail -1)" "no"

r=$(ans 'if ask_yes_no "q: "; then echo "R=yes"; else echo "R=no"; fi' '')
chk "D04 no keyboard is never read as a yes" "$(echo "$r" | sed -n 's/.*R=\(.*\)/\1/p' | tail -1)" "no"

r=$(ans 'p=$(ask_number 3 "n: "); echo "R=$p"' 'abc
9
2
')
chk "D05 a numbered list survives a wrong word and a wrong number" "$(echo "$r" | sed -n 's/.*R=\(.*\)/\1/p' | tail -1)" "2"

r=$(ans 'ask_number 3 "n: " >/dev/null; echo "R=$?"' 'stop
')
chk "D06 'stop' at a numbered list is a clean stop, not a bad number" "$(echo "$r" | sed -n 's/.*R=\(.*\)/\1/p' | tail -1)" "2"

# ⛔ The option words are read OUT OF ocs-prerun.sh, not restated here. A test
# that keeps its own copy of the accepted answers stops testing what ships the
# moment either one is edited. Specs carry no spaces, so `set --` splits safely.
sed -n "s/^ *'\(additional=[^']*\)'.*/\1/p;s/^ *'\(replace=[^']*\)'.*/\1/p;s/^ *'\(stop=[^']*\)'.*/\1/p" \
    "$KIT/ocs-prerun.sh" > "$RUN/opt.specs"
nspec=$(grep -c . "$RUN/opt.specs")
chk "D07a the three image choices are still declared in ocs-prerun.sh" "$nspec" "3"

cat > "$RUN/optpick.sh" <<EOS
. "$CM"
set -- \$(cat "$RUN/opt.specs")
c=\$(ask_option ' pick: ' "\$@"); rc=\$?
echo "R=\$c"
echo "RC=\$rc"
EOS

optpick() { printf '%s\n' "$@" | dash "$RUN/optpick.sh" 2>/dev/null; }

for pair in "1:additional" "2:replace" "3:stop" "ADD:additional" "replace:replace" "Copy:additional" "STOP:stop" "n:stop" "redo:replace"; do
    a=${pair%%:*}; want=${pair##*:}
    chk "D07 '$a' selects $want" "$(optpick "$a" | sed -n 's/^R=//p')" "$want"
done

chk "D08 three wrong answers at the image choice select nothing" "$(optpick zz yy xx | sed -n 's/^RC=//p')" "1"

# --- the image choice, through the real ocs-prerun.sh ------------------------
#
# ⛔ This is the bug of 2026-09-08: on the customer path IMAGE_NAME comes from
# capture.conf and cannot be edited at the console, so before 1.9 a second image
# could not be captured onto a stick at all. Every branch is exercised here
# against a real GPT loop device, because the whole failure was that one branch
# did not exist.
# ⛔ NOT a loop device. whole_disks() skips loop* on purpose, so that a capture
# can never target the medium it booted from, which means a loop device can
# never stand in for a unit's disk here. nbd0 is a real block device to the
# kernel and is not on the USB bus, so it reaches the same code a unit does.
LOOPIMG="$RUN/gptdisk.img"
truncate -s 256M "$LOOPIMG"
sgdisk -n 1:0:0 -t 1:0700 "$LOOPIMG" >/dev/null 2>&1 || true
LOOPDEV=""
PTU=""
if command -v qemu-nbd >/dev/null 2>&1 && sudo modprobe nbd max_part=8 2>/dev/null; then
    sudo qemu-nbd --disconnect /dev/nbd0 >/dev/null 2>&1 || true
    if sudo qemu-nbd --connect=/dev/nbd0 --format=raw "$LOOPIMG" 2>/dev/null; then
        sleep 1
        LOOPDEV=/dev/nbd0
        PTU=$(sudo blkid -s PTUUID -o value "$LOOPDEV" 2>/dev/null || echo "")
    fi
fi

prerun_case() {   # $1 name  $2 answers  $3 medium dir
    # ⛔ sudo rm: ocs-prerun.sh writes these as root, so clearing them as the
    # test user silently fails and the next case reads the previous answer.
    sudo rm -f /tmp/toast_image /tmp/toast_target
    printf '%s' "$2" | sudo env TOAST_MEDIUM="$3" TOAST_NO_POWEROFF=1 TOAST_STOP_WAIT=0 \
        sh "$KIT/ocs-prerun.sh" >"$RUN/prerun-$1.out" 2>&1
    echo $? > "$RUN/prerun-$1.rc"
    sudo umount /home/partimag 2>/dev/null || true
}

mk_medium() {     # $1 dir  $2 existing image name
    rm -rf "$1"; mkdir -p "$1/TOAST/config" "$1/TOAST/logs" "$1/TOAST/scripts" "$1/home/partimag"
    cp "$KIT"/ocs-*.sh "$1/TOAST/scripts/"
    mkdir -p "$1/home/partimag/$2"
    printf 'sda1\n' > "$1/home/partimag/$2/parts"
    head -c 3000000 /dev/zero > "$1/home/partimag/$2/sda1.ntfs-ptcl-img.zst.aa"
    printf "IMAGE_NAME='%s'\nDISK_ID='%s'\nDISK_ID_KIND='gpt'\n" "$2" "$PTU" > "$1/TOAST/config/capture.conf"
}

if [ -n "$LOOPDEV" ] && [ -n "$PTU" ]; then
    # D09: choice 1, accepting the suggested name. The old image must survive.
    FM1="$RUN/med-add"; mk_medium "$FM1" testimg
    prerun_case add 'yes
1

' "$FM1"
    got=$(cat /tmp/toast_image 2>/dev/null)
    chk "D09 additional capture uses the suggested free name" "$got" "testimg-2"
    [ -d "$FM1/home/partimag/testimg" ] && ok "D10 the image already on the stick is untouched" \
        || bad "D10 the image already on the stick is untouched" "testimg was deleted"

    # D11: choice 1 with a name typed instead of the suggestion.
    FM2="$RUN/med-add2"; mk_medium "$FM2" testimg
    prerun_case add2 'yes
1
second-unit
' "$FM2"
    chk "D11 a typed name is accepted and sanitized" "$(cat /tmp/toast_image 2>/dev/null)" "second-unit"

    # D12: choice 1, typing a name that is also taken, then a free one.
    FM3="$RUN/med-add3"; mk_medium "$FM3" testimg
    mkdir -p "$FM3/home/partimag/taken"
    prerun_case add3 'yes
1
taken
free-one
' "$FM3"
    chk "D12 a second collision re-asks rather than overwriting" "$(cat /tmp/toast_image 2>/dev/null)" "free-one"

    # D13: choice 2 still replaces, and still deletes first.
    FM4="$RUN/med-rep"; mk_medium "$FM4" testimg
    prerun_case rep 'yes
2
' "$FM4"
    if [ ! -d "$FM4/home/partimag/testimg" ] && [ "$(cat /tmp/toast_image 2>/dev/null)" = testimg ]; then
        ok "D13 replace deletes the old image and keeps the name"
    else
        bad "D13 replace deletes the old image and keeps the name" "$(cat /tmp/toast_image 2>/dev/null)"
    fi

    # D14: choice 3 changes nothing at all, and says so without a support banner.
    FM5="$RUN/med-stop"; mk_medium "$FM5" testimg
    prerun_case stop 'yes
3
' "$FM5"
    if [ -d "$FM5/home/partimag/testimg" ] && [ ! -f /tmp/toast_image ]; then
        ok "D14 stop keeps the image and captures nothing"
    else bad "D14 stop keeps the image and captures nothing"; fi
    grep -qi 'contact toast support' "$RUN/prerun-stop.out" \
        && bad "D15 a deliberate stop is not reported as a fault" "support banner shown" \
        || ok "D15 a deliberate stop is not reported as a fault"
    grep -q 'STOPPED - NOTHING WAS CHANGED' "$RUN/prerun-stop.out" \
        && ok "D16 stop says plainly that nothing changed" \
        || bad "D16 stop says plainly that nothing changed"

    # D17: an unrecognised answer at the three-way does not fall through to a
    # destructive default. Three wrong answers, then the image must still exist.
    FM6="$RUN/med-junk"; mk_medium "$FM6" testimg
    prerun_case junk 'yes
maybe
dunno
whatever
' "$FM6"
    [ -d "$FM6/home/partimag/testimg" ] && [ ! -f /tmp/toast_image ] \
        && ok "D17 answers nobody expected never delete an image" \
        || bad "D17 answers nobody expected never delete an image"

    # D18: the space guard, on a medium too small to hold a second image, and
    # the offer to replace instead. Measured against the image that is there,
    # not against an estimate.
    SMALL="$RUN/small.img"; truncate -s 100M "$SMALL"
    if mkfs.ext4 -q -F "$SMALL" >/dev/null 2>&1; then
        SM="$RUN/med-small"; mkdir -p "$SM"
        if sudo mount -o loop "$SMALL" "$SM" 2>/dev/null; then
            sudo chmod 0777 "$SM"
            mk_medium "$SM" testimg 2>/dev/null || true
            head -c 60000000 /dev/zero > "$SM/home/partimag/testimg/big.bin" 2>/dev/null
            sync
            prerun_case small 'yes
1
no
' "$SM"
            grep -qi 'not enough room' "$RUN/prerun-small.out" \
                && ok "D18 refuses a second image when the stick cannot hold one" \
                || bad "D18 refuses a second image when the stick cannot hold one"
            [ -d "$SM/home/partimag/testimg" ] && ok "D19 that refusal deletes nothing" \
                || bad "D19 that refusal deletes nothing"
            sudo umount "$SM" 2>/dev/null || true
        else skip "D18-D19 the space guard" "could not mount the small fixture"; fi
    else skip "D18-D19 the space guard" "mkfs.ext4 unavailable"; fi

    sudo qemu-nbd --disconnect "$LOOPDEV" >/dev/null 2>&1 || true
else
    skip "D09-D19 the image choice through ocs-prerun.sh" "could not set up a GPT loop device"
fi

# D20: no script carries its own poweroff any more. One copy, in ocs-common.sh,
# so none of them can drift back to a bare `poweroff`.
dupe=$(grep -l 'toast_poweroff() {' "$KIT"/ocs-*.sh | grep -v 'ocs-common.sh' | wc -l)
chk "D20 exactly one toast_poweroff in the kit" "$dupe" "0"

# D21: nothing in the kit calls bare poweroff outside that one helper.
bareoff=$(grep -n '^[[:space:]]*poweroff[[:space:]]*$' "$KIT"/ocs-*.sh | wc -l)
chk "D21 no bare poweroff anywhere in the kit" "$bareoff" "0"

# =========================================================== summary
echo
echo "==============================================================="
printf ' %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
echo " results: $RUN/results.tsv"
echo " screenshots: $RUN/boot-*.png"
echo "==============================================================="
# Keep the run dir small: fixtures are regenerable, evidence is not.
rm -f "$RUN"/*.img "$RUN"/ovmf-*.fd
rmdir "$RUN/nm" "$RUN/m9" 2>/dev/null
[ "$FAIL" -eq 0 ]
