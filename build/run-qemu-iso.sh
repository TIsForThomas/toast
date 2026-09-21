#!/bin/bash
# Boot a kit ISO under QEMU (UEFI) and screendump the menu.
set -u
ISO=$1; TAG=$2; DELAY=${3:-8}; TOTAL=${4:-60}
SOCK=/tmp/qmp-$TAG.sock
rm -f "$SOCK" "scr_$TAG.ppm" "serial_$TAG.log"
cp -f /usr/share/OVMF/OVMF_VARS_4M.fd ovmf_vars_$TAG.fd
qemu-system-x86_64 -enable-kvm -m 4096 -smp 2 \
  -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,unit=1,file=ovmf_vars_$TAG.fd \
  -drive if=none,id=cd,file="$ISO",format=raw,media=cdrom \
  -device ide-cd,drive=cd,bootindex=0 \
  -serial "file:serial_$TAG.log" -display none \
  -qmp "unix:$SOCK,server,nowait" -no-reboot &
Q=$!
sleep "$DELAY"
printf '{"execute":"qmp_capabilities"}\n{"execute":"screendump","arguments":{"filename":"%s/scr_%s.ppm"}}\n' "$PWD" "$TAG" \
  | timeout 20 socat - "UNIX-CONNECT:$SOCK" >/dev/null 2>&1
echo "screendump at ${DELAY}s"
for i in $(seq 1 "$TOTAL"); do kill -0 $Q 2>/dev/null || { echo "qemu exited after ${i}s"; exit 0; }; sleep 1; done
kill $Q 2>/dev/null; echo "killed after ${TOTAL}s"
