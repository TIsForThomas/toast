# TOAST

**T**he **O**ffline **A**utomated **S**ysprep **T**oolkit.

One bootable USB stick that a customer runs on a computer they have already set up
the way they want it. It generalizes the Windows install, captures the disk with
Clonezilla, and hands back an image plus the answer file that describes how the
machine should come up. Nobody has to talk them through it, and nothing on their
machine is lost if they get a step wrong.

The whole thing is shell and PowerShell. About 7,000 lines, no runtime beyond what
Clonezilla and Windows already ship.

```
kit/TOAST/     the Linux half: seven Clonezilla hook scripts
windows/       the Windows half: the wizard that runs before the reboot
build/         makes the stick, the ISO, and the boot menus
test/          56 checks that run the real scripts, not copies of them
```

## The problem this solves

A customer configures a machine: their software, their settings, their domain, their
weird line-of-business app that nobody can reinstall from scratch. They want fifty more
of them. The normal answer is that they ship the machine somewhere and somebody images
it by hand.

Clonezilla on its own does not close that gap:

- **It cannot restore onto a smaller disk.** partclone writes used blocks at their
  original filesystem offsets, and NTFS keeps a backup boot sector at the very last
  sector of the volume. A 953 GiB filesystem writes past the end of a smaller partition
  no matter how little data is in it. No restore-time flag fixes this. `-icds` only
  silences the size check, and `-r` runs after a successful restore, which is too late.
  The shrink has to happen before the bitmap is taken.
- **It does not know which disk it is looking at.** "The first disk" is wrong on any
  machine with a second drive, and it is wrong in a way that destroys data.
- **It asks questions a customer cannot answer**, in a menu that will happily start
  something irreversible if they press Enter twice.

So the kit does the shrink at capture time (the same thing FOG does, which is why FOG
can restore to a smaller disk when stock Clonezilla cannot), resolves the target disk
by identity rather than by position, and replaces the whole Clonezilla front end with
four menu entries and a script that only ever asks questions with a safe default.

## How a run goes

**Step 1, in Windows.** They double-click one file. The wizard checks the machine is in
a state that can be captured at all (BitLocker fully decrypted, not just suspended;
no per-user AppX packages that will block `sysprep /generalize`; enough free space on
the stick for the image it is about to make), asks them how the deployed machines should
be set up, writes `unattend.xml` and a `capture.conf` naming the disk to copy, runs
sysprep, and shuts the machine down by itself.

**Step 2, from the stick.** They boot it. `ocs-prerun.sh` reads `capture.conf`, finds
that disk again, shows them what it is about to do, and asks once. Then the shrink runs,
Clonezilla captures, and the filesystem is put back to full size before the machine
powers off.

**Step 3.** They send back `home/partimag/` and `TOAST/config/unattend.xml`.

The same stick deploys. Once their image is on it, it will put that image onto a unit
whose drive was swapped or failed, and the replacement drive does not have to match the
original size.

## The parts worth reading

### `ocs-shrink.sh`, and putting it back

The shrink is the reason the kit exists, and the expand-back is the reason it is safe.

Every `ntfsresize` call against an already-resized volume passes `-f`. A successful
shrink *schedules a chkdsk*, which marks the volume, and `ntfsresize` then refuses to
touch it. Without `-f` the expand-back fails silently and leaves the customer with a
small filesystem sitting inside a large partition. `-f -f` does not suppress the
scheduling whatever the help text implies; only `ntfsfix -d` clears the flag, and it has
to run after the shrink too, or the flag gets captured and every machine deployed from
that image runs a chkdsk on first boot.

The expand-back runs on every exit path: a failed capture, a canceled capture, a
non-zero exit from `ocs-sr`, or a signal. It is called explicitly *and* from a trap,
because `poweroff` at the end of the capture does not reliably let an EXIT trap finish.
Calling it twice is safe because it clears its own state file on success.

The shrink target is the `ntfsresize` minimum plus 15%, floored at 3 GiB. That margin is
not about upload size. partclone stores used blocks only, so a 46 GiB and a 36 GiB
filesystem holding the same data produce near-identical images. The margin exists so the
restore has somewhere to absorb alignment loss on a target disk that is not laid out
like the source.

### `ocs-prerun.sh`, picking the disk

The target is resolved by GPT disk GUID or MBR signature first, and only falls back to
the vendor serial. If neither resolves to exactly one disk, it refuses and says so. It
never picks the first disk, and it never picks "the one that has Windows on it" when
there is more than one candidate.

It also catches the case where the stick was prepared on a *different* computer: the
answers on it name a disk this machine does not have, so it stops and tells them to run
step 1 here first, rather than capturing the wrong machine.

`capture.conf` is parsed, not sourced. It is a file on a FAT32 stick that a customer can
open in Notepad, so it can come back with CRLF line endings, and disk model strings
contain spaces. Sourcing it would put a stray carriage return inside the image directory
name.

### `ocs-preflight.sh`, refusing before writing

The deploy does its own size check before Clonezilla starts, and refuses a target that
is too small while printing what the image needs, what the disk provides, and the
shortfall.

This is not belt-and-braces. Clonezilla's `ocs-expand-gpt-pt` sets
`chk_tgt_disk_size_bf_mk_pt` and then never tests it, so `-k1` will cheerfully build a
proportionally smaller partition table and let the restore die inside partclone twenty
minutes later, on a disk it has already overwritten.

There is a one-megabyte pad in that calculation with a comment explaining why it is not
larger: it once refused a 1:1 restore of an image back onto its own original disk, short
by 709 KB, because the captured filesystem is already slightly smaller than its
partition and an exact fit has only a few hundred KB of headroom.

### `ocs-common.sh`, asking questions once

Every prompt in the kit reads its answer through this file. Nothing re-implements one.

An unrecognized answer is never taken as a no. It used to be, and typing `yse` aborted a
capture that had already taken twenty minutes. Answers can be given by number or by
word, and every prompt retries three times before giving up.

It also owns `toast_poweroff()`, which had been pasted into four scripts, and
`stop_cleanly()`. The distinction between `stop_cleanly()` and `fail()` matters: a
deliberate "no" must never call `fail()`, because `fail()` prints a contact-support
banner, and Clonezilla runs the next hook regardless, so the capture script then adds a
second, contradictory error message on top of a perfectly normal decision to stop.

## Testing

`test/test-toast.sh` runs 56 numbered checks in four groups against a built ISO:

- **A**, static checks on the ISO. Payload names survive the plain ISO9660 namespace
  (which folds case), exactly one runnable file sits where the customer will look,
  the shipped scripts hash-match the working tree, the version on the disc matches the
  filename.
- **B**, it actually boots, BIOS and UEFI.
- **C**, the engine. The shrink and expand subcommands take a device *or a plain file*,
  which is what lets the whole shrink and expand path run on a build server against an
  NTFS image with no block device and no unit involved.
- **D**, the answer handling. Every branch of the "this stick already holds an image"
  choice, and every way a prompt can be answered badly.

The disk fixture is an **nbd** device, not a loop device. A loop device cannot stand in,
because the kit's `whole_disks()` skips `loop*` by design so that a capture can never
target the medium it is running from. Testing against a loop device would test a code
path that does not exist in production.

The tests run the real scripts. `test-toast.sh` mounts the finished ISO and hashes what
is on it against `kit/TOAST/`, so a check that passes is a statement about the artifact
a customer would receive.

## The shipping gate

Two files in this kit go to a customer with their comments intact. `build/build-kit.sh`,
`build/build-kit-iso.sh` and `build/write-kit` all grep them against
`build/leak-patterns.txt` and **refuse to build** on a hit, and `test-toast.sh` re-checks
the finished ISO.

This exists because it already happened. The Windows wizard used to be generated at
build time by a splicing script, and it shipped carrying a comment naming an internal
build share. Worse, when that script's own source was retired, the generated copy on the
stick silently fell 754 lines behind the real one (1,590 against 2,344, with an entire
feature missing) and kept building cleanly every time. The wizard is now read straight
from `windows/` with no generator in between, which is what makes that class of drift
impossible rather than merely unlikely.

## Building a stick

```bash
cd build
bash build-kit.sh                  # FAT32 filesystem + bootable disk image
bash build-kit-iso.sh              # hybrid ISO, BIOS and UEFI
sudo ./write-kit /dev/sdX          # write a real stick at the device's full size
sudo ./write-kit --image kit.img --size 238G   # or one for QEMU
```

`write-kit` exists instead of `dd kit.img /dev/sdX` because the built image is a 2.9 GB
FAT32 filesystem with 2.4 GB free, which cannot hold a capture. `dd` onto a 256 GB stick
leaves 253 GB of it unreachable. `write-kit` builds the filesystem at the device's real
size with 32 KiB clusters, then verifies what it wrote.

Before it touches anything it checks that the target is a whole disk, that it sits on
the USB bus (a 256 GB USB SSD reports `removable=0`, so "is it removable" is the wrong
question), that nothing on it is mounted, and that it is not backing any mounted
filesystem or any member of any assembled RAID array on the host.

The legacy BIOS bootloader is installed with Clonezilla's *own* bundled syslinux, not
the host's. The installer replaces `ldlinux.c32` but leaves the other modules alone, so
a host syslinux 6.04 writing a loader next to Clonezilla's 6.03 modules produces a boot
that gets as far as `SYSLINUX` and then loops forever on `Undef symbol FAIL:
x86_init_fpu`. Bootloader and modules have to come from one version.

## About this copy

This is a cleaned-up copy of a tool built for a hardware manufacturer, published as a
portfolio piece. The product name and the on-stick folder are renamed, the two internal
paths that the build tooling knew about are now configuration, and the leak pattern list
ships with generic defaults for you to add your own hostnames to. Nothing else about the
logic has been changed.

`build/make-background.sh` composes the boot splash from a wordmark and a licensed
typeface that are deliberately **not** in this repo. Point `BRAND` at your own, or drop
a 640x480 PNG in as `build/toast-bg.png` and skip it.

Clonezilla itself is not vendored here. `build/` expects a Clonezilla live tree at
`build/cz/`.

## Status

Proven on real hardware: a full capture including the shrink (252,841,292,288 bytes down
to a 38 GB filesystem), the expand-back, Windows booting afterwards with C: at full size
and no chkdsk, and a deploy from the stick onto a unit.

The build, the ISO, the boot paths and every branch of the script logic are covered by
the test suite and run on each build. What a test suite cannot cover is the long tail of
real firmware, so the honest summary is that the mechanism is proven and the coverage
across models is not.

## License

MIT. See `LICENSE`.
