#!/bin/bash
# Rebuild kitfs.img (the FAT32 filesystem) and kit.img (the bootable disk) from
# kit/TOAST/ plus the regenerated boot configs. Run from build/.
set -euo pipefail

python3 patch_grub.py
python3 patch_syslinux.py

# Payload, listed explicitly rather than by wildcard: the source folders also hold
# .bak_* revert copies, and a stale ocs-prerun.sh.bak on the stick would be a
# confusing thing for a customer or a support call to find.
#
# TWO SOURCES, on purpose (2026-09-04):
#   kit/TOAST/   the Linux half and the kit's own docs
#   windows/     the Windows half, maintained as its own tree
#
# ⛔ The Windows half is NOT copied into kit/TOAST/ and must not be. It used to
# be spliced together here by a generator that read from a source script which
# was later retired, and the copy on the stick silently fell 754 lines behind
# the real one (1590 vs 2344 lines, a whole feature missing) while still
# building cleanly every time. Reading it straight from its own tree is what
# makes that class of drift impossible.
WINDOWS_SRC=${WINDOWS_SRC:-../windows}

# Shipping gate, loaded from build/leak-patterns.txt so the list of internal
# names lives in one place and never inside a file that ships.
LEAK_PATTERNS=${LEAK_PATTERNS:-"$(dirname "$0")/leak-patterns.txt"}
LEAK_RE=$(grep -vE '^[[:space:]]*(#|$)' "$LEAK_PATTERNS" | paste -sd'|')
[ -n "$LEAK_RE" ] || { echo "no leak patterns loaded from $LEAK_PATTERNS" >&2; exit 1; }

# From 1.4 the machinery lives in TOAST/scripts/ so the customer opens TOAST\
# and sees one runnable file. config/ and logs/ stay at the TOAST/ level.
mmd -i kitfs.img ::/TOAST/scripts 2>/dev/null || true
for f in KIT-VERSION.txt START-HERE.md; do
    [ -f "../kit/TOAST/$f" ] || { echo "missing payload file: $f" >&2; exit 1; }
    mcopy -o -i kitfs.img "../kit/TOAST/$f" ::/TOAST/
done
for f in ocs-common.sh ocs-prerun.sh ocs-capture.sh ocs-shrink.sh ocs-deploy.sh ocs-repair.sh ocs-preflight.sh; do
    [ -f "../kit/TOAST/$f" ] || { echo "missing payload file: $f" >&2; exit 1; }
    mcopy -o -i kitfs.img "../kit/TOAST/$f" ::/TOAST/scripts/
done

for f in Prepare-Sysprep-USB.ps1 Run-Toast-Prep.cmd; do
    [ -s "$WINDOWS_SRC/$f" ] || { echo "missing Windows payload: $WINDOWS_SRC/$f" >&2; exit 1; }
    # The .ps1 is nested so it cannot be double-clicked; the .cmd stays on top.
    case "$f" in *.ps1) dest=::/TOAST/scripts/ ;; *) dest=::/TOAST/ ;; esac
    # SHIPPING GATE. These two files go to a customer and their comments ship
    # with them, so an internal share path or server address in either is a
    # build failure, not a warning. The retired generated wizard carried exactly
    # such a comment, naming an internal build share by name.
    if grep -qE "$LEAK_RE" "$WINDOWS_SRC/$f"; then
        echo "REFUSING TO BUILD: $f contains an internal path or address:" >&2
        grep -nE "$LEAK_RE" "$WINDOWS_SRC/$f" >&2
        exit 1
    fi
    mcopy -o -i kitfs.img "$WINDOWS_SRC/$f" "$dest"
done
mmd -i kitfs.img ::/TOAST/config 2>/dev/null || true
mmd -i kitfs.img ::/TOAST/logs   2>/dev/null || true
[ -r toast-bg.png ] || bash make-background.sh >/dev/null
mcopy -o -i kitfs.img toast-bg.png ::/syslinux/ocswp.png
mcopy -o -i kitfs.img toast-bg.png ::/boot/grub/ocswp-grub2.png
mcopy -o -i kitfs.img grub.cfg.new    ::/boot/grub/grub.cfg
mcopy -o -i kitfs.img syslinux.cfg.new ::/syslinux/syslinux.cfg

# A master must never ship with the state a previous run left behind: capture
# state, one customer's answers, or another unit's upload sheet.
# ⛔ kitfs.img is a REUSED FAT image, so mcopy never removes anything. When the
# machinery moved into TOAST/scripts/ in 1.4, the old top-level copies stayed
# behind and the master shipped both. Delete them explicitly.
for moved in ocs-prerun.sh ocs-capture.sh ocs-shrink.sh ocs-deploy.sh \
             ocs-repair.sh ocs-preflight.sh Prepare-Sysprep-USB.ps1; do
    mdel -i kitfs.img "::/TOAST/$moved" 2>/dev/null || true
done

for stale in ::/TOAST/config/capture.done ::/TOAST/config/capture.conf \
             ::/TOAST/config/unattend.xml ::/TOAST/config/shrink.state \
             ::/TOAST/logs/capture.log ::/TOAST/logs/shrink.log ::/TOAST/logs/deploy.log \
             ::/TOAST/logs/windows-step1.log; do
    mdel -i kitfs.img "$stale" 2>/dev/null || true
done

# Legacy BIOS bootloader.
#
# MUST use Clonezilla's OWN bundled installer (utils/linux/x64/syslinux, 6.03), not
# the host's /usr/bin/syslinux. The installer writes ldlinux.sys AND replaces
# ldlinux.c32 with its own version, but leaves the other modules on the medium
# (vesamenu/libcom32/libutil/menu/chain.c32) alone -- those are Clonezilla's 6.03.
# Installing with the host's 6.04 produced a boot that got as far as SYSLINUX and
# then looped forever on:
#     Undef symbol FAIL: x86_init_fpu
#     Failed to load libcom32.c32
# because a 6.04 loader cannot load 6.03 modules. Bootloader and modules must come
# from one syslinux version.
cz/utils/linux/x64/syslinux -d syslinux -f -i kitfs.img
python3 mkkit.py
