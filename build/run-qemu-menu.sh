#!/bin/bash
# Boot the kit and screendump the boot menu before the timeout auto-boots it.
# Usage: run-qemu-menu.sh <kitimg> <tag> [shot_delay_s] [total_s]
set -u
KITIMG=$1; TAG=$2; DELAY=${3:-6}; TOTAL=${4:-150}
SOCK=/tmp/qmp-$TAG.sock
rm -f "$SOCK" "serial_$TAG.log" "scr_$TAG.ppm"
cp -f /usr/share/OVMF/OVMF_VARS_4M.fd ovmf_vars_$TAG.fd

qemu-system-x86_64 -enable-kvm -m 4096 -smp 2 \
  -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,unit=1,file=ovmf_vars_$TAG.fd \
  -device qemu-xhci,id=xhci \
  -drive if=none,id=kitdrv,file="$KITIMG",format=raw \
  -device usb-storage,bus=xhci.0,drive=kitdrv,bootindex=0 \
  -serial "file:serial_$TAG.log" \
  -display none -qmp "unix:$SOCK,server,nowait" -no-reboot &
QPID=$!
sleep "$DELAY"
printf '{"execute":"qmp_capabilities"}\n{"execute":"screendump","arguments":{"filename":"%s/scr_%s.ppm"}}\n' "$PWD" "$TAG" \
  | timeout 20 socat - "UNIX-CONNECT:$SOCK" >/dev/null 2>&1
echo "screendump taken at ${DELAY}s"
for i in $(seq 1 "$TOTAL"); do
  kill -0 $QPID 2>/dev/null || { echo "qemu exited after ${i}s"; exit 0; }
  sleep 1
done
kill $QPID 2>/dev/null
echo "killed after ${TOTAL}s"
