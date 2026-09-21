# Wrap the FAT32 filesystem image in an MBR-partitioned disk image.
# The 440-byte boot code is Clonezilla's own mbr.bin (from utils/mbr/), which
# chainloads the active partition -- without it a legacy-BIOS machine finds no
# boot code and falls through to "no bootable device". UEFI ignores this entirely
# and boots /EFI/boot/bootx64.efi, which is why the omission went unnoticed.
import struct, os
SEC = 512
START = 2048
fs = open('kitfs.img', 'rb').read()
nsec = len(fs) // SEC
total = START + nsec + 2048

def chs(l):
    l = min(l, 1023 * 255 * 63)
    c = l // (255 * 63); h = (l // 63) % 255; s = l % 63 + 1
    return bytes([h, ((c >> 2) & 0xC0) | s, c & 0xFF])

bootcode = open('cz/utils/mbr/mbr.bin', 'rb').read()
assert len(bootcode) == 440, 'mbr.bin must be 440 bytes, got %d' % len(bootcode)

with open('kit.img', 'wb') as f:
    mbr = bytearray(START * SEC)
    mbr[0:440] = bootcode
    e = (bytes([0x80]) + chs(START) + bytes([0x0c]) + chs(START + nsec - 1)
         + struct.pack('<II', START, nsec))
    mbr[0x1BE:0x1BE + 16] = e
    mbr[0x1FE:0x200] = b'\x55\xAA'
    mbr[0x1B8:0x1BC] = b'\x54\x47\x4B\x54'   # disk signature 'TGKT'
    f.write(mbr); f.write(fs); f.write(b'\0' * (2048 * SEC))
print("kit.img %.0f MB, bootcode %d bytes, partition LBA %d, %d sectors"
      % (total * SEC / 1e6, len(bootcode), START, nsec))
