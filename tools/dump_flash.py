#!/usr/bin/env python3
# Dump memory-mapped flash via U-Boot 'md.l', verify each chunk with U-Boot 'crc32'.
import serial, sys, re, struct, zlib, time
BASE, SIZE, CHUNK = 0xF8000000, 0x400000, 0x10000
out = sys.argv[1]
s = serial.Serial('/dev/ttyUSB0', 115200, timeout=2)
def cmd(c, end=b'Marvell>> '):
    s.reset_input_buffer(); s.write(c.encode() + b'\r'); buf = b''
    while not buf.endswith(end):
        d = s.read(65536)
        if not d: raise TimeoutError(buf[-300:])
        buf += d
    return buf.decode('latin1')
data = bytearray()
for off in range(0, SIZE, CHUNK):
    a = BASE + off
    for attempt in range(5):
        txt = cmd('md.l %x %x' % (a, CHUNK // 4))
        chunk = bytearray()
        for m in re.finditer(r'^([0-9a-f]{8}):((?: [0-9a-f]{8}){1,4})', txt, re.M):
            if int(m.group(1), 16) != a + len(chunk): break
            for w in m.group(2).split(): chunk += struct.pack('<I', int(w, 16))
        crc = re.search(r'==> ([0-9a-f]{8})', cmd('crc32 %x %x' % (a, CHUNK)))
        if len(chunk) == CHUNK and crc and int(crc.group(1), 16) == zlib.crc32(chunk):
            break
        print('retry %x len=%d' % (a, len(chunk)), flush=True)
    else:
        sys.exit('FAILED at %x' % a)
    data += chunk
    open(out, 'wb').write(data)
    print('ok %08x (%d%%)' % (a, 100 * (off + CHUNK) // SIZE), flush=True)
print('DONE', len(data))
