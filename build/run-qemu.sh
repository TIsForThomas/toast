#!/bin/bash
# Boot the kit under QEMU. Usage: run-qemu.sh <bios|uefi|uefi-sb> <tag> [target.img] [timeout_s]
# The kit is always attached as a USB mass-storage device behind an xHCI controller,
# so the boot medium really is USB and not a plain disk.
set -u
MODE=$1; TAG=$2; TGT=${3:-target.img}; TMO=${4:-420}
SOCK=/tmp/qmp-$TAG.sock
rm -f "$SOCK" "serial_$TAG.log"

FW=()
case "$MODE" in
  bios)    : ;;
  uefi)    cp -f /usr/share/OVMF/OVMF_VARS_4M.fd ovmf_vars_$TAG.fd
           FW=(-drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd
               -drive if=pflash,format=raw,unit=1,file=ovmf_vars_$TAG.fd) ;;
  uefi-sb) cp -f /usr/share/OVMF/OVMF_VARS_4M.ms.fd ovmf_vars_$TAG.fd
           FW=(-drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd
               -drive if=pflash,format=raw,unit=1,file=ovmf_vars_$TAG.fd
               -global driver=cfi.pflash01,property=secure,value=on
               -machine q35,smm=on) ;;
  *) echo "unknown mode $MODE"; exit 2 ;;
esac

qemu-system-x86_64 -enable-kvm -m 4096 -smp 2 \
  "${FW[@]}" \
  -device qemu-xhci,id=xhci \
  -drive if=none,id=kitdrv,file=${KITIMG:-kit.img},format=raw \
  -device usb-storage,bus=xhci.0,drive=kitdrv,bootindex=0 \
  -drive if=none,id=tgt,file="$TGT",format=raw \
  -device virtio-blk-pci,drive=tgt,serial=${TGTSERIAL:-TOASTTEST01},bootindex=1 \
  -serial "file:serial_$TAG.log" \
  -display none -qmp "unix:$SOCK,server,nowait" \
  -no-reboot &
QPID=$!
echo "qemu pid $QPID, mode $MODE, log serial_$TAG.log, qmp $SOCK"
for i in $(seq 1 $TMO); do
  kill -0 $QPID 2>/dev/null || { echo "qemu exited after ${i}s"; exit 0; }
  sleep 1
done
echo "TIMEOUT after ${TMO}s -- capturing screen and killing"
printf '{"execute":"qmp_capabilities"}\n{"execute":"screendump","arguments":{"filename":"%s/scr_%s.ppm"}}\n' "$PWD" "$TAG" \
  | timeout 20 socat - "UNIX-CONNECT:$SOCK" >/dev/null 2>&1
kill $QPID 2>/dev/null
exit 1
