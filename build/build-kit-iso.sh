#!/bin/bash
# Build a TOAST Image Capture Kit ISO, for creating sticks on WINDOWS with Rufus.
#
# WHY AN ISO AT ALL
# write-kit builds a stick directly, but it is a Linux tool and has to run on this
# server. To create a stick from a Windows laptop you need something Rufus can
# consume, and Rufus is also the practical answer to a hard Windows limitation:
# Windows cannot format FAT32 above 32 GB with any built-in tool (format, diskpart
# and Format-Volume all refuse), and a UEFI-bootable removable partition must be
# FAT32. Rufus carries its own FAT32 formatter, so it can make the whole 256 GB
# stick one bootable FAT32 volume. That is the reason to route through it.
#
# ⛔ RUFUS MUST BE USED IN "ISO IMAGE" MODE, NOT "DD IMAGE" MODE.
# ISO mode creates a full-size FAT32 partition, extracts the files and installs a
# bootloader, so the remaining ~255 GB stays writable and can hold the capture.
# DD mode copies the ISO byte for byte, leaving a ~600 MB read-only volume with
# the rest of the drive unallocated, which cannot hold an image at all. Rufus
# prompts for the choice on a hybrid ISO like this one.
#
# The ISO is hybrid (isolinux for BIOS, efi.img for UEFI) so it also works with
# dd, Ventoy, or Clonezilla's own utils/win32/makeboot.bat route.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CZ="$HERE/cz"
KIT="$HERE/../kit/TOAST"
WINDOWS_SRC=${WINDOWS_SRC:-$HERE/../windows}
STAGE="$HERE/iso-stage"
OUT="${1:-$HERE/TOAST-$(tr -d ' \r\n' < "$KIT/KIT-VERSION.txt").iso}"

KIT_TOP=( KIT-VERSION.txt START-HERE.md )
KIT_SCRIPTS=( ocs-common.sh ocs-prerun.sh ocs-capture.sh ocs-shrink.sh ocs-deploy.sh ocs-repair.sh ocs-preflight.sh )
WIN_TOP=( Run-Toast-Prep.cmd )
WIN_SCRIPTS=( Prepare-Sysprep-USB.ps1 )
KIT_PAYLOAD=( "${KIT_TOP[@]}" "${KIT_SCRIPTS[@]}" )
WIN_PAYLOAD=( "${WIN_TOP[@]}" "${WIN_SCRIPTS[@]}" )
# Shipping gate: anything that must not appear in a file a customer receives,
# comments included. One place, loaded from build/leak-patterns.txt, so the list
# of internal names never lives inside a file that ships.
LEAK_PATTERNS=${LEAK_PATTERNS:-"$HERE/leak-patterns.txt"}
LEAK_RE=$(grep -vE '^[[:space:]]*(#|$)' "$LEAK_PATTERNS" | paste -sd'|')
[ -n "$LEAK_RE" ] || { echo "no leak patterns loaded from $LEAK_PATTERNS" >&2; exit 1; }

[ -d "$CZ/live" ] || { echo "Clonezilla tree missing at $CZ" >&2; exit 1; }
[ -f "$HERE/grub.cfg.new" ] && [ -f "$HERE/syslinux.cfg.new" ] \
  || { echo "run: python3 patch_grub.py && python3 patch_syslinux.py" >&2; exit 1; }
for f in "${KIT_PAYLOAD[@]}"; do [ -f "$KIT/$f" ] || { echo "missing $f" >&2; exit 1; }; done

# Same shipping gate as write-kit: these files reach a customer and their comments
# ship with them, so an internal path in either is a build failure.
for f in "${WIN_PAYLOAD[@]}"; do
    [ -s "$WINDOWS_SRC/$f" ] || { echo "missing Windows payload: $WINDOWS_SRC/$f" >&2; exit 1; }
    if grep -qE "$LEAK_RE" "$WINDOWS_SRC/$f"; then
        echo "REFUSING TO BUILD: $f contains an internal path or address:" >&2
        grep -nE "$LEAK_RE" "$WINDOWS_SRC/$f" >&2
        exit 1
    fi
done

rm -rf "$STAGE"; mkdir -p "$STAGE"
# Symlink farm so the 532 MB squashfs is not copied.
for d in EFI boot live syslinux utils; do cp -as "$CZ/$d" "$STAGE/"; done
# ⛔ --remove-destination is MANDATORY here. The staging tree is a symlink farm,
# so a plain `cp -f` onto these paths writes THROUGH the symlink and overwrites
# the pristine Clonezilla config in cz/. That happened on 2026-09-04: it polluted
# cz/syslinux/syslinux.cfg and cz/boot/grub/grub.cfg, and the next
# patch_syslinux.py run then generated a config with our three menu entries
# TWICE. Restored from cz.zip. --remove-destination unlinks the symlink first.
cp --remove-destination "$HERE/grub.cfg.new"     "$STAGE/boot/grub/grub.cfg"
cp --remove-destination "$HERE/syslinux.cfg.new" "$STAGE/syslinux/syslinux.cfg"
# ⛔ isolinux.cfg too. An ISO booted on legacy BIOS is read by isolinux, which
# uses isolinux.cfg; syslinux.cfg is only used once syslinux is installed onto a
# USB stick. Missing this made a BIOS boot of the ISO come up with Clonezilla's
# stock menu and no TOAST entries at all. Found by booting it under SeaBIOS.
cp --remove-destination "$HERE/isolinux.cfg.new" "$STAGE/syslinux/isolinux.cfg"

# TOAST wallpaper in place of Clonezilla's. Both boot paths reference their own
# copy by name, so both get replaced. --remove-destination again: these are
# symlinks into cz/ and writing through them would vandalise the pristine tree.
[ -r "$HERE/toast-bg.png" ] || bash "$HERE/make-background.sh" >/dev/null
cp --remove-destination "$HERE/toast-bg.png" "$STAGE/syslinux/ocswp.png"
cp --remove-destination "$HERE/toast-bg.png" "$STAGE/boot/grub/ocswp-grub2.png"

# LAYOUT, from 1.4. The customer opens TOAST\ and sees exactly one runnable
# file. Everything that is machinery goes in scripts\, including the .ps1 so it
# cannot be double-clicked by mistake. config\ and logs\ stay at the TOAST\
# level because START-HERE.md tells the customer to send us \TOAST\logs\.
mkdir -p "$STAGE/TOAST/config" "$STAGE/TOAST/logs" "$STAGE/TOAST/scripts" "$STAGE/home/partimag"
for f in "${KIT_TOP[@]}";     do cp -f "$KIT/$f" "$STAGE/TOAST/"; done
for f in "${KIT_SCRIPTS[@]}"; do cp -f "$KIT/$f" "$STAGE/TOAST/scripts/"; done
for f in "${WIN_TOP[@]}";     do cp -f "$WINDOWS_SRC/$f" "$STAGE/TOAST/"; done
for f in "${WIN_SCRIPTS[@]}"; do cp -f "$WINDOWS_SRC/$f" "$STAGE/TOAST/scripts/"; done

# Rufus in ISO mode installs its own bootloader, but keep a real hybrid layout so
# the same file also works with dd and Ventoy.
# ⛔ -relaxed-filenames -U ARE LOAD-BEARING. Without them, xorriso mangles the
# PLAIN ISO9660 namespace, which is what some extractors (Rufus included) read
# instead of Joliet:
#     ocs-prerun.sh                    -> ocs_prerun.sh
#     KIT-VERSION.txt                  -> kit_version.txt
#     Prepare-Sysprep-USB.ps1 -> prepare_sysprep_customer_us.ps1
# ISO9660 forbids hyphens, so they became underscores, and the name was truncated
# to 30 characters as well. A stick written from such an ISO boots to
# "failed to run sh /run/live/medium/TOAST/ocs-prerun.sh" because the file on
# the stick is called ocs_prerun.sh. Hit at the bench on 2026-09-04.
# -relaxed-filenames permits the hyphen; -U disables name translation entirely so
# nothing is truncated. Case is still folded to lower, which does not matter
# because the destination is FAT32 and its lookups are case-insensitive.
xorriso -as mkisofs \
  -iso-level 3 -J -joliet-long -R -follow-links \
  -relaxed-filenames -U \
  -V TOAST \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -b syslinux/isolinux.bin -c syslinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot -isohybrid-gpt-basdat \
  -o "$OUT" "$STAGE"

rm -rf "$STAGE"

# --- verify the ISO9660 namespace, not just Joliet -------------------------
# This is the check that would have caught the hyphen mangling before a stick was
# written. It reads the ISO the way a non-Joliet extractor does and insists every
# payload name survives intact, case-insensitively.
VERIFY_MNT=$(mktemp -d)
if sudo mount -o ro,loop,norock,nojoliet "$OUT" "$VERIFY_MNT" 2>/dev/null; then
    miss=0
    tdir=$(ls "$VERIFY_MNT" | grep -i '^toast$' | head -1)
    if [ -z "$tdir" ]; then
        echo "VERIFY FAILED: no TOAST directory in the plain ISO9660 namespace" >&2
        miss=1
    else
        sdir=$(ls "$VERIFY_MNT/$tdir" | grep -i '^scripts$' | head -1)
        [ -n "$sdir" ] || { echo "VERIFY FAILED: no TOAST/scripts directory" >&2; miss=1; }
        for f in "${KIT_TOP[@]}" "${WIN_TOP[@]}"; do
            if [ -z "$(ls "$VERIFY_MNT/$tdir" | grep -ix "$f" | head -1)" ]; then
                echo "VERIFY FAILED: '$f' mangled or missing in TOAST/" >&2
                ls "$VERIFY_MNT/$tdir" | sed 's/^/    have: /' >&2
                miss=1; break
            fi
        done
        for f in "${KIT_SCRIPTS[@]}" "${WIN_SCRIPTS[@]}"; do
            if [ -z "$(ls "$VERIFY_MNT/$tdir/$sdir" 2>/dev/null | grep -ix "$f" | head -1)" ]; then
                echo "VERIFY FAILED: '$f' mangled or missing in TOAST/scripts/" >&2
                ls "$VERIFY_MNT/$tdir/$sdir" 2>/dev/null | sed 's/^/    have: /' >&2
                miss=1; break
            fi
        done
    fi
    [ -d "$VERIFY_MNT/home/partimag" ] || { echo "VERIFY FAILED: home/partimag missing" >&2; miss=1; }
    # All three boot configs must carry all three entries. Checking only one is
    # how the isolinux.cfg gap survived until a real BIOS boot exposed it.
    for cfg in boot/grub/grub.cfg syslinux/syslinux.cfg syslinux/isolinux.cfg; do
        n=$(grep -ci 'TOAST' "$VERIFY_MNT/$cfg" 2>/dev/null || echo 0)
        if [ "$n" -lt 3 ]; then
            echo "VERIFY FAILED: $cfg has $n TOAST lines, expected the three menu entries" >&2
            miss=1
        fi
    done
    sudo umount "$VERIFY_MNT"
    rmdir "$VERIFY_MNT"
    if [ "$miss" -ne 0 ]; then
        echo "Refusing to ship $OUT" >&2
        rm -f "$OUT"
        exit 1
    fi
    echo "ISO9660 namespace verified: all payload names intact"
else
    rmdir "$VERIFY_MNT" 2>/dev/null
    echo "WARNING: could not mount the ISO to verify its ISO9660 names (needs sudo)" >&2
fi

ls -la "$OUT"
echo
echo "Windows: open Rufus, select this ISO, choose ISO Image mode (NOT DD), write."
echo "The stick will then be one full-size FAT32 volume with the rest free for images."
