#!/bin/bash
# End-to-end test of the whole auto-capture / auto-deploy loop, using the lab
# VM's real Windows disk as the source. This is the test that closes the biggest
# remaining gap: the deploy restore has never actually run.
#
#   1. shut the lab VM down cleanly
#   2. boot the kit in QEMU with the VM's 512 GiB Windows disk attached
#      -> bench prompt, shrink, capture, expand back
#   3. boot the kit again with a BLANK SMALLER disk attached
#      -> deploy, which must pass pre-flight and restore
#   4. boot the restored disk on its own and confirm Windows starts
#
# Step 3 is the point. A 512 GiB source restored onto a 256 GB target is exactly
# the real customer case that started this work: a vendor image captured from a
# 1 TB drive that has to land on whatever drive the replacement unit shipped with.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# Point these at your own lab VM's disks.
#   KIT  a kit image built by  write-kit --image KIT --size 256G
#   SRC  the Windows disk to capture, as a qcow2
#   TGT  a blank, deliberately SMALLER disk to restore onto
KIT=${KIT:?set KIT to a kit image built by write-kit}
SRC=${SRC:?set SRC to the lab VM Windows disk as a qcow2}
TGT=${TGT:?set TGT to a blank target disk image}
TGT_SIZE=${TGT_SIZE:-256060514304}      # a real 256 GB SSD, in bytes
PHASE=${1:-help}

case "$PHASE" in
  prep)
    echo "== shutting the lab VM down cleanly =="
    sudo virsh shutdown win11iot 2>/dev/null || true
    for i in $(seq 1 60); do
      sudo virsh domstate win11iot 2>/dev/null | grep -q 'shut off' && break
      sleep 5
    done
    sudo virsh domstate win11iot
    echo "== creating a blank $((TGT_SIZE/1000000000)) GB target =="
    rm -f "$TGT"; truncate -s "$TGT_SIZE" "$TGT"
    ls -la "$TGT"
    ;;

  capture)
    # The kit is USB; the Windows disk is SATA, as on a real unit. qcow2 is
    # attached directly so the VM's own disk is the source of truth - no
    # conversion, no second copy that could drift.
    echo "== booting the kit against the lab VM's Windows disk =="
    sudo chown libvirt-qemu:kvm "$SRC" 2>/dev/null || true
    sudo qemu-system-x86_64 -enable-kvm -m 4096 -smp 4 \
      -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
      -drive if=pflash,format=raw,unit=1,file="$HERE/ovmf_vars_e2ecap.fd" \
      -device qemu-xhci,id=xhci \
      -drive if=none,id=kitdrv,file="$KIT",format=raw \
      -device usb-storage,bus=xhci.0,drive=kitdrv,bootindex=0 \
      -drive if=none,id=win,file="$SRC",format=qcow2 \
      -device ide-hd,bus=ide.0,drive=win,serial=TOASTLAB-SRC-001 \
      -serial "file:$HERE/serial_e2ecap.log" \
      -display none -qmp "unix:/tmp/qmp-e2ecap.sock,server,nowait" -no-reboot
    ;;

  deploy)
    echo "== booting the kit against a blank smaller target =="
    sudo qemu-system-x86_64 -enable-kvm -m 4096 -smp 4 \
      -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
      -drive if=pflash,format=raw,unit=1,file="$HERE/ovmf_vars_e2edep.fd" \
      -device qemu-xhci,id=xhci \
      -drive if=none,id=kitdrv,file="$KIT",format=raw \
      -device usb-storage,bus=xhci.0,drive=kitdrv,bootindex=0 \
      -drive if=none,id=tgt,file="$TGT",format=raw \
      -device ide-hd,bus=ide.0,drive=tgt,serial=TOASTLAB-TGT-001 \
      -serial "file:$HERE/serial_e2edep.log" \
      -display none -qmp "unix:/tmp/qmp-e2edep.sock,server,nowait" -no-reboot
    ;;

  verify)
    echo "== booting the restored target on its own =="
    cp -f /usr/share/OVMF/OVMF_VARS_4M.fd "$HERE/ovmf_vars_e2ever.fd"
    sudo qemu-system-x86_64 -enable-kvm -m 4096 -smp 4 -machine q35 \
      -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
      -drive if=pflash,format=raw,unit=1,file="$HERE/ovmf_vars_e2ever.fd" \
      -drive if=none,id=tgt,file="$TGT",format=raw \
      -device ide-hd,bus=ide.0,drive=tgt,bootindex=0 \
      -serial "file:$HERE/serial_e2ever.log" \
      -display none -qmp "unix:/tmp/qmp-e2ever.sock,server,nowait" -no-reboot
    ;;

  *)
    echo "usage: $0 {prep|capture|deploy|verify}"
    echo
    echo "  prep     shut the lab VM down and create a blank 256 GB target"
    echo "  capture  boot the kit against the VM's Windows disk and capture it"
    echo "  deploy   boot the kit against the blank target and restore into it"
    echo "  verify   boot the restored target and confirm Windows starts"
    echo
    echo "Both capture and deploy are INTERACTIVE (bench prompt, typed serial),"
    echo "so drive them with vmshot/QMP screendumps and QMP sendkey, or attach"
    echo "a console. They are deliberately not scripted blind: these are the"
    echo "confirmations that stop a wrong disk being overwritten."
    ;;
esac
