#!/usr/bin/env python3
# Log console, spam Ctrl-C / space at autoboot prompt, exit once a U-Boot prompt answers.
import serial, sys, time, re
log = open(sys.argv[1], 'wb')
s = serial.Serial('/dev/ttyUSB0', 115200, timeout=0.05)
buf = b''; t0 = time.time(); hit = None
while time.time() - t0 < 900:
    d = s.read(4096)
    if d:
        buf += d; log.write(d); log.flush()
    if hit is None and re.search(rb'(?i)(hit any key|autoboot|U-Boot 1\.|Marvell>>|\b__\s)', buf):
        hit = time.time()
    if hit and time.time() - hit < 15:
        s.write(b'\x03 '); time.sleep(0.02)
        if re.search(rb'(Marvell>>|=>|\w+>\s*$)', buf[-200:]) and time.time()-hit > 3:
            s.write(b'\r'); time.sleep(1); log.write(s.read(4096)); break
log.close()
print(open(sys.argv[1], 'rb').read().decode('latin1')[-4000:])
