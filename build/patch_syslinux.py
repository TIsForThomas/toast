# Regenerate a TOAST syslinux.cfg (legacy BIOS boot path) from Clonezilla's stock one.
# The entry list and kernel cmdline are imported from patch_grub.py so the two boot
# paths can never drift -- a difference between them is exactly the kind of bug that
# only shows up on whichever firmware nobody tested.
import re
import patch_grub as pg

# THREE boot paths, not two, and they must all carry the same entries:
#   boot/grub/grub.cfg      UEFI, via GRUB          (patch_grub.py)
#   syslinux/syslinux.cfg   BIOS from a USB stick   (syslinux installs this)
#   syslinux/isolinux.cfg   BIOS from an ISO/CD     (isolinux reads this)
#
# ⛔ isolinux.cfg was missed until 2026-09-04 and the consequence was silent: a
# legacy-BIOS boot of the ISO came up with Clonezilla's STOCK menu and none of
# the TOAST entries, because isolinux reads isolinux.cfg while syslinux reads
# syslinux.cfg. They are two near-identical standalone files, not an include.
# Found by actually booting the ISO under SeaBIOS.
SOURCES = {
    'cz/syslinux/syslinux.cfg': 'syslinux.cfg.new',
    'cz/syslinux/isolinux.cfg': 'isolinux.cfg.new',
}

for src, dst in SOURCES.items():
    s = open(src, encoding='utf8', errors='replace').read()

    # Canary. The source must be the PRISTINE Clonezilla config. If it already
    # carries TOAST entries, something wrote through the staging symlink farm
    # into cz/, and patching again would duplicate every entry.
    if 'TOAST' in s:
        raise SystemExit(
            f"{src} is already patched (contains 'TOAST').\n"
            "Something wrote through the symlink farm into cz/. Restore it with:\n"
            f"  unzip -o -j cz.zip '{src[3:]}' -d /tmp/p && cp -f /tmp/p/$(basename {src}) {src}")


    # "If 'serial' directive exists, it must be the first directive" -- stock
    # cfg's own warning. Harmless on a unit with no serial port, and it is how
    # support reads a failed boot off a bench cable.
    s = 'serial 0 115200\n' + s

    # Only one label may carry MENU DEFAULT. Drop it from Clonezilla's.
    s = re.sub(r'\n  MENU DEFAULT\n', '\n  # MENU DEFAULT\n', s, count=1)
    # ⛔ No auto-boot: 0 means wait for input indefinitely in syslinux. Same
    # reason as the GRUB side.
    s = s.replace('timeout 300', 'timeout 0')

    block = ''
    for e in pg.ENTRIES:
        block += f'label {e["label"]}\n'
        if e.get('default'):
            block += '  MENU DEFAULT\n'
        block += (
            f'  MENU LABEL {e["title"]}\n'
            '  kernel /live/vmlinuz\n'
            f'  append initrd=/live/initrd.img {pg.cmdline_for(e)}\n'
            '  TEXT HELP\n'
            f'  {e["help"]}\n'
            '  ENDTEXT\n\n'
        )

    i = s.index('label Clonezilla live\n')
    s = s[:i] + block + s[i:]
    open(dst, 'w', encoding='utf8').write(s)
    print(f'{dst}: {len(pg.ENTRIES)} entries inserted at char {i}')
