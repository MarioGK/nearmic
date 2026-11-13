#!/usr/bin/env python3
"""Rebuild the USB gadget whenever the computer drops and re-attaches the link.

After a re-enumeration of the running gadget (the computer rebooted or woke
up, the cable was replugged, a power transient reset the port), the composite
device reaches "configured" but stops answering USB audio class requests: the
computer logs `cannot get freq`, `failed to get current value ... (-110)`,
spends about three minutes on 30 s timeouts before the microphone appears, and
the USB network function fails to bind (seen 2026-11-11 09:22, 13:06 and
2026-11-12 21:09). A gadget that was freshly bound enumerates in under a
second (boot, and `systemctl restart nearmic-gadget` on 2026-11-11 18:04).

So: watch the UDC state (sysfs `state` supports poll), and when it leaves
"configured" for anything but "suspended", restart nearmic-gadget once. The
computer then sees a fresh device. PipeWire re-creates the two ALSA nodes and
the link supervisors re-link them within a few seconds.
"""
import os
import select
import subprocess
import sys
import time

UDC = os.environ.get("NEARMIC_UDC", "fe800000.usb")
STATE = f"/sys/class/udc/{UDC}/state"
COOLDOWN_S = 20


def log(msg):
    print(f"nearmic-udc-watch: {msg}", flush=True)


def main():
    while not os.path.exists(STATE):
        time.sleep(5)
    fd = os.open(STATE, os.O_RDONLY)
    poller = select.poll()
    poller.register(fd, select.POLLPRI | select.POLLERR)

    def read():
        os.lseek(fd, 0, os.SEEK_SET)
        return os.read(fd, 64).decode().strip()

    last = read()
    was_configured = last == "configured"
    quiet_until = 0.0
    log(f"watching {STATE}, state '{last}'")
    while True:
        poller.poll(5000)
        state = read()
        if state == last:
            continue
        if state == "configured":
            was_configured = True
        elif state != "suspended" and was_configured and time.time() >= quiet_until:
            log(f"link left 'configured' ({last} -> {state}): rebinding the gadget for a clean enumeration")
            was_configured = False
            quiet_until = time.time() + COOLDOWN_S
            subprocess.run(["systemctl", "restart", "nearmic-gadget.service"], check=False)
            state = read()
        last = state


if __name__ == "__main__":
    sys.exit(main())
