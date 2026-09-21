#!/bin/bash
# Produce kit-e2e.img: the real master with one test capture.conf added, then put
# kitfs.img back the way it was so the master stays pristine.
set -euo pipefail
GUID=$(tr 'A-Z' 'a-z' < target_gpt.guid | tr -d '\n')
cat > e2e-capture.conf <<CONF
# Written by Prepare-Sysprep-USB.ps1 -- read by ocs-prerun.sh.
IMAGE_NAME='acmecorp-tb-7293-20260824'
DISK_ID='$GUID'
DISK_ID_KIND='gpt-guid'
DISK_SERIAL='WRONGSERIAL999'
DISK_MODEL='QEMU VIRTIO TESTDISK 1'
USED_BYTES='41943040'
CUSTOMER='Acme Corp'
MODEL='TB-7293'
UNIT_SERIAL='2603003252'
CREATED='2026-08-24T10:40:00'
KIT_VERSION='1.0'
CONF
# Deliberately CRLF: this is what a Notepad round-trip on the stick produces, and
# the parser is supposed to survive it.
sed -i 's/$/\r/' e2e-capture.conf
mcopy -o -i kitfs.img e2e-capture.conf ::/TOAST/config/capture.conf
python3 mkkit.py
mv -f kit.img kit-e2e.img
# Restore the master.
mdel -i kitfs.img ::/TOAST/config/capture.conf 2>/dev/null || true
python3 mkkit.py
echo "kit-e2e.img ready; master kit.img rebuilt clean"
mdir -i kitfs.img ::/TOAST/config
