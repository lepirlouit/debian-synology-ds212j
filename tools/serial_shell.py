#!/usr/bin/env python3
# Minimal serial shell driver for the DS-212j Debian console.
#   serial_shell.py login <password>
#   serial_shell.py run '<cmd>' [timeout]
#   serial_shell.py put <local> <remote>     (base64 over the console, checked with sha256)
import serial, sys, time, re, base64, hashlib
PROMPT = re.compile(rb'root@ds212j:[^#]*# $')
s = serial.Serial('/dev/ttyUSB0', 115200, timeout=0.2)

def read_until(rx, t=10):
    buf = b''; end = time.time() + t
    while time.time() < end:
        d = s.read(65536)
        if d:
            buf += d
            if rx.search(buf): return buf.decode('latin1')
    raise TimeoutError(buf[-500:].decode('latin1'))

def write_slow(data):
    # The console UART has no flow control: pace the input so no character is lost
    for i in range(0, len(data), 8):
        s.write(data[i:i+8]); s.flush(); time.sleep(0.01)

def run(cmd, t=30):
    s.reset_input_buffer()
    write_slow(b'{ echo __BEGIN__; ' + cmd.encode() + b'\n} 2>&1; echo __END__\n')
    out = read_until(re.compile(rb'\n__END__\r?\n.*# $', re.S), t).replace('\r', '')
    return out.split('__BEGIN__', 1)[-1].lstrip('\n').rsplit('\n__END__', 1)[0]

op = sys.argv[1]
if op == 'login':
    s.write(b'\n'); time.sleep(1)
    buf = s.read(65536)
    if PROMPT.search(buf): print('already logged in'); sys.exit()
    s.write(b'root\n'); read_until(re.compile(rb'Password: ?$'))
    s.write(sys.argv[2].encode() + b'\n'); read_until(PROMPT, 20)
    run('export PS2= TERM=dumb PAGER=cat SYSTEMD_PAGER=cat SYSTEMD_COLORS=0; stty -echo cols 200')
    print('logged in')
elif op == 'run':
    print(run(sys.argv[2], float(sys.argv[3]) if len(sys.argv) > 3 else 30))
elif op == 'put':
    data = open(sys.argv[2], 'rb').read(); dst = sys.argv[3]
    run(f"rm -f {dst}.b64")
    b64 = base64.encodebytes(data).decode().splitlines()
    for i in range(0, len(b64), 40):
        chunk = '\n'.join(b64[i:i+40])
        run(f"cat >> {dst}.b64 <<'__EOF__'\n{chunk}\n__EOF__", 30)
    run(f"base64 -d {dst}.b64 > {dst} && rm {dst}.b64")
    remote = run(f"sha256sum {dst}").split()[0]
    local = hashlib.sha256(data).hexdigest()
    print('OK' if remote == local else 'MISMATCH', dst, remote)
    sys.exit(remote != local)
