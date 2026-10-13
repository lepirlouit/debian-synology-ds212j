#!/usr/bin/env python3
# usage: ser.py [-t secs] [-u regex] [cmd ...]  -- send each cmd line, read until regex or timeout
import serial, sys, time, re, argparse
p = argparse.ArgumentParser()
p.add_argument('-t', type=float, default=5)
p.add_argument('-u', default=None)
p.add_argument('--raw', action='store_true', help='send without CR')
p.add_argument('cmds', nargs='*')
a = p.parse_args()
s = serial.Serial('/dev/ttyUSB0', 115200, timeout=0.2)
out = b''
for c in a.cmds or ['']:
    c = c.encode().decode('unicode_escape').encode('latin1')
    s.write(c if a.raw else c + b'\r')
    time.sleep(0.3)
t = time.time()
while time.time() - t < a.t:
    d = s.read(65536)
    if d:
        out += d; sys.stdout.write(d.decode('latin1')); sys.stdout.flush()
        if a.u and re.search(a.u.encode(), out): break
