#!/bin/bash
# Build a GPT test target disk for the end-to-end capture test, without root:
# format the FAT partition with mtools, concatenate it into a whole-disk image,
# then let sgdisk write the GPT headers onto the assembled file.
set -euo pipefail
SEC=512; START=2048; PSEC=2095070
rm -f target_gpt.img fat_part.img payload.bin marker.txt

truncate -s $((PSEC * SEC)) fat_part.img
mformat -i fat_part.img -F -v TGTDATA -T $PSEC ::
mmd -i fat_part.img ::/Windows
mmd -i fat_part.img ::/Windows/System32
dd if=/dev/urandom of=payload.bin bs=1M count=38 status=none
echo "hello from the target" > marker.txt
mcopy -i fat_part.img payload.bin ::/Windows/
mcopy -i fat_part.img marker.txt ::/Windows/System32/
md5sum payload.bin marker.txt > target_gpt.md5

python3 - <<'PY'
SEC = 512; START = 2048; PSEC = 2095070; TOTAL = 1024*1024*1024 // SEC
with open('target_gpt.img', 'wb') as f:
    f.write(b'\0' * (START * SEC))
    with open('fat_part.img', 'rb') as p:
        while True:
            b = p.read(1 << 20)
            if not b: break
            f.write(b)
    f.write(b'\0' * ((TOTAL - START - PSEC) * SEC))
print('assembled target_gpt.img')
PY

sgdisk -og target_gpt.img
sgdisk -n 1:$START:$((START + PSEC - 1)) -t 1:0700 -c 1:Basic target_gpt.img
sgdisk -p target_gpt.img | grep -E 'Disk identifier|^ +1'
sgdisk -p target_gpt.img | awk '/Disk identifier/{print $4}' > target_gpt.guid
echo "disk GUID: $(cat target_gpt.guid)"
