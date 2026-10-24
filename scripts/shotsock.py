#!/usr/bin/env python3
"""Ask QEMU's monitor for a framebuffer dump over its unix socket.

    shotsock.py <monitor.sock> <out.ppm>

The dockur image is a minimal Debian and may have neither socat nor nc, but it
does ship python3 - and HMP needs nothing more than "write a line, read the
reply". The monitor speaks plain text and answers "screendump" by writing a P6
PPM at the path given, so there is no protocol to speak here.

Exits non-zero when the PPM did not appear, so the caller can tell "the monitor
refused" from "the monitor worked and the screen is black".
"""
import os
import socket
import sys
import time


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: shotsock.py <monitor.sock> <out.ppm>")
    sock_path, out_path = sys.argv[1], sys.argv[2]

    if not os.path.exists(sock_path):
        sys.exit(f"no monitor socket at {sock_path}")

    # A stale PPM from an earlier attempt would look like success.
    try:
        os.unlink(out_path)
    except FileNotFoundError:
        pass

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(20)
    try:
        s.connect(sock_path)
        # Greeting first: HMP prints its banner and prompt on connect and may
        # not accept a command until that is drained.
        time.sleep(0.5)
        try:
            s.recv(8192)
        except socket.timeout:
            pass
        s.sendall(f"screendump {out_path}\n".encode())
        time.sleep(2)
        try:
            reply = s.recv(8192).decode(errors="replace")
        except socket.timeout:
            reply = ""
    finally:
        s.close()

    print(f"monitor said: {reply.strip() or '(nothing)'}")

    if not os.path.exists(out_path):
        sys.exit(f"no {out_path} after screendump")
    print(f"wrote {out_path} ({os.path.getsize(out_path)} bytes)")


main()
