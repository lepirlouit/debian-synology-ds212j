#!/usr/bin/env python3
# Reset the board from its U-Boot prompt, immediately UART-boot a kwbimage with kwboot
# (RAM only, nothing is flashed), then log the console for a while.
# usage: kwboot_test.py <kwboot> <u-boot.kwb> <logfile> [seconds] [reset-command]
#   reset-command: 'reset' at a U-Boot prompt (default), 'reboot' at a Linux root shell
#   KWBOOT_STOP=1 in the environment: stop autoboot and leave the board at the U-Boot prompt
import os, re, serial, subprocess, sys, time
kwboot, img, logf = sys.argv[1:4]
secs = float(sys.argv[4]) if len(sys.argv) > 4 else 180
resetcmd = sys.argv[5] if len(sys.argv) > 5 else 'reset'
s = serial.Serial('/dev/ttyUSB0', 115200, timeout=0.2)
s.write(b'\x03\r'); time.sleep(0.3); s.reset_input_buffer()
s.write(resetcmd.encode() + b'\r'); s.flush(); s.close()
r = subprocess.run([kwboot, '-b', img, '-B', '115200', '/dev/ttyUSB0'])
print('kwboot exit', r.returncode, flush=True)
if r.returncode:
    sys.exit(r.returncode)
s = serial.Serial('/dev/ttyUSB0', 115200, timeout=0.2)
log = open(logf, 'wb'); t = time.time(); buf = b''
stop = os.environ.get('KWBOOT_STOP') == '1'
while time.time() - t < secs:
    d = s.read(65536)
    if d:
        log.write(d); log.flush(); buf += d
    if stop and b'Hit any key' in buf:
        s.write(b' ')
        if re.search(rb'DS212j> $', buf):
            break
