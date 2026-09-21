import struct, sys
SEC=512; START=2048
fs=open('p2.img','rb').read()
nsec=len(fs)//SEC
total=START+nsec+2048
img=bytearray(total*SEC)
img[START*SEC:START*SEC+len(fs)]=fs
def chs(l):
    l=min(l,1023*255*63)
    c=l//(255*63); h=(l//63)%255; s=l%63+1
    return bytes([h, ((c>>2)&0xC0)|s, c&0xFF])
e=bytes([0x80])+chs(START)+bytes([0x0c])+chs(START+nsec-1)+struct.pack('<II',START,nsec)
img[0x1BE:0x1BE+16]=e
img[0x1FE:0x200]=b'\x55\xAA'
img[0x1B8:0x1BC]=b'\x54\x45\x47\x55'
open('target.img','wb').write(img)
print("target.img %.0f MB, partition LBA %d, %d sectors" % (total*SEC/1e6, START, nsec))
