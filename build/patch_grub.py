# Regenerate grub.cfg.new from the stock Clonezilla grub.cfg.orig.
#
# This file must stay byte-equivalent to the config that was actually booted and
# tested. Three things here are load-bearing and were each paid for with a failed
# boot -- see TEST-RESULTS.md bugs 1 and 2:
#   * /run/live/medium, NOT /lib/live/mount/medium. Current live-boot moved it.
#   * console=ttyS0 FIRST, console=tty0 LAST. The last console= becomes
#     /dev/console, and Clonezilla exits unless that is tty0/tty1.
#   * $linux_cmd / $initrd_cmd, not linux / initrd -- the stock grub.cfg sets
#     these for the signed-boot path and a hardcoded "linux" breaks Secure Boot.
# Also: no toram=. Loading to RAM can unmount the medium we must write to.

MEDIUM = '/run/live/medium'

# Everything except the two ocs_* hooks, which differ per menu entry.
CMDLINE_BASE = (
    'boot=live union=overlay username=user config loglevel=3'
    ' hostname=toast-kit noswap edd=on nomodeset enforcing=0 noeject'
    ' locales=en_US.UTF-8 keyboard-layouts=us'
    ' ocs_live_batch="yes" ocs_live_extra_param=""'
    ' net.ifnames=0 console=ttyS0,115200n8 console=tty0 nvme.poll_queues=1'
)

# One entry per thing a person can choose to do. Capture stays first and stays
# the default, so the customer flow is unchanged: they boot the stick and it
# captures, exactly as before.
ENTRIES = [
    dict(
        id='toast-capture',
        title='TOAST: Capture image from this unit',
        label='TOASTCapture',
        help='* Captures this unit to the TOAST USB drive. Unattended.',
        prerun=f'sh {MEDIUM}/TOAST/scripts/ocs-prerun.sh',
        run=f'sh {MEDIUM}/TOAST/scripts/ocs-capture.sh',
        default=True,
    ),
    dict(
        id='toast-deploy',
        title='TOAST: Deploy an image to this unit',
        label='TOASTDeploy',
        help='* Writes an image from the USB drive ONTO this unit. Destroys its disk.',
        # No ocs_prerun: the capture prerun requires capture.conf and refuses
        # without it, which is correct for capture and wrong for deploy. The
        # deploy script does its own disk resolution and confirmation.
        prerun=None,
        run=f'sh {MEDIUM}/TOAST/scripts/ocs-deploy.sh',
    ),
    dict(
        id='toast-repair',
        title='TOAST: Repair disk space after an interrupted capture',
        label='TOASTRepair',
        help='* Only needed if a capture lost power partway. Restores full disk size.',
        prerun=None,
        run=f'sh {MEDIUM}/TOAST/scripts/ocs-repair.sh',
    ),
]


def cmdline_for(e):
    parts = [CMDLINE_BASE]
    if e.get('prerun'):
        parts.append(f'ocs_prerun="{e["prerun"]}"')
    parts.append(f'ocs_live_run="{e["run"]}"')
    return ' '.join(parts)


if __name__ == '__main__':
    s = open('grub.cfg.orig', encoding='utf8', errors='replace').read()

    block = ''
    for e in ENTRIES:
        block += (
            f'menuentry "{e["title"]}" --id {e["id"]} {{\n'
            '  search --set -f /live/vmlinuz\n'
            f'  $linux_cmd /live/vmlinuz {cmdline_for(e)}\n'
            '  $initrd_cmd /live/initrd.img\n'
            '}\n\n'
        )

    i = s.index('menuentry "Clonezilla live (VGA 800x600)"')
    s = s[:i] + block + s[i:]
    default = next(e['id'] for e in ENTRIES if e.get('default'))
    s = s.replace('set default="0"', f'set default="{default}"')
    # ⛔ No auto-boot. -1 means wait for a keypress forever. A 10 second timer
    # was too short to read three entries and decide, and it started a capture
    # on its own. Asked for 2026-09-05. The default entry stays highlighted so
    # Enter is still one keypress.
    s = s.replace('set timeout="30"', 'set timeout="-1"')
    open('grub.cfg.new', 'w', encoding='utf8').write(s)
    print(f'grub.cfg.new: {len(ENTRIES)} entries inserted at char {i}, default {default}')
