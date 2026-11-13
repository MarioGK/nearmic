#!/usr/bin/env python3
"""Keep U-Boot's default boot order eMMC-first.

Armbian's U-Boot 2022.07 for the ROCK 4 Plus ships
`boot_targets=usb0 mmc1 mmc0 ...`: it starts USB and probes the host ports
before the eMMC, and with the Wi-Fi adapter or the audio interface plugged in
the board did not reach Linux (2026-11-10/11). The image builder patches the
string in place; this guard re-applies the same-length patch if a bootloader
update (armbian-install, a forced u-boot update) ever restores the stock order.

It only ever rewrites that one 47-byte string, and only when it finds exactly
one stock copy in the boot area. Runs at boot and after every dpkg run.

Second patch, same mechanism and OPT-IN (see VBUS_FLAG): U-Boot does not
power the USB host ports.
Its device tree marks `vcc5v0_host` (GPIO4_D1, the 5 V switch for the USB-A
host ports) as an always-on fixed regulator, so U-Boot turns the ports on about
a second after power is applied. With the Maono and the Wi-Fi adapter plugged
in, every start from power-off then hung before Linux (green LED, no blue),
while starts with nothing plugged in, restarts with power already on, and
hot-plugging the same devices later all worked (2026-11-10..12). Released, the
enable line reads low and the ports are unpowered (measured on the running
board), so renaming the node's `compatible` from "regulator-fixed" to an
unmatched string of the same length leaves the ports off through the
bootloader. Linux switches them on a few seconds later from its own device
tree, once the supply has settled.

    nearmic-uboot-guard                 # the running board: eMMC boot area + package file
    nearmic-uboot-guard FILE[:LIMIT]... # image builder: patch these files instead
"""
import glob
import os
import sys

OLD = b"boot_targets=usb0 mmc1 mmc0 nvme0 pxe dhcp sf0 "
VBUS_NODE = b"\x00\x00\x00\x01vcc5v0-host-regulator\x00"
VBUS_OLD = b"regulator-fixed\x00"
VBUS_NEW = b"regulator-nmoff\x00"
# The USB-power patch is opt-in: it has never completed a boot on the board
# (the one start attempted with it, 2026-11-12, hung, with a powered hub
# attached at the same time, so the cause is not separated). Create this file
# to apply it; without the file the guard restores the stock value.
VBUS_FLAG = "/etc/nearmic/uboot-usb-power-off"

NEW = b"boot_targets=mmc1 mmc0 nvme0 usb0 pxe dhcp sf0 "
BOOT_AREA = 32768 * 512  # everything before the first partition


def patch(path, limit=0):
    try:
        fd = os.open(path, os.O_RDWR)
    except OSError as exc:
        print(f"nearmic-uboot-guard: cannot open {path}: {exc}")
        return 1
    try:
        data = b""
        want = limit or os.fstat(fd).st_size
        while len(data) < want:
            chunk = os.pread(fd, min(1 << 20, want - len(data)), len(data))
            if not chunk:
                break
            data += chunk
        rc = 0
        # USB host power: the first "compatible" value after the node header.
        nodes = [i for i in range(len(data)) if data.startswith(VBUS_NODE, i)] if VBUS_NODE in data else []
        for at in nodes:
            win = data[at : at + 256]
            want_off = os.path.exists(VBUS_FLAG)
            # The node's own "compatible" is the first of the two strings after
            # its header; the next regulator node (also "regulator-fixed") is
            # inside the same window and must not be mistaken for it.
            hits = [(win.find(v), v) for v in (VBUS_OLD, VBUS_NEW) if win.find(v) >= 0]
            if not hits:
                print(f"nearmic-uboot-guard: {path}: vcc5v0_host node found but not a fixed regulator; not touching it")
                rc = 1
                continue
            pos, cur = min(hits)
            if cur == VBUS_NEW and want_off:
                print(f"nearmic-uboot-guard: {path}: USB host power left to Linux")
            elif cur == VBUS_OLD and not want_off:
                print(f"nearmic-uboot-guard: {path}: stock USB host power (U-Boot powers the ports)")
            elif want_off:
                os.pwrite(fd, VBUS_NEW, at + pos)
                os.fsync(fd)
                print(f"nearmic-uboot-guard: {path}: U-Boot no longer powers the USB host ports (byte {at + pos})")
            else:
                os.pwrite(fd, VBUS_OLD, at + pos)
                os.fsync(fd)
                print(f"nearmic-uboot-guard: {path}: restored stock USB host power (byte {at + pos})")
        if not nodes:
            print(f"nearmic-uboot-guard: {path}: no vcc5v0-host-regulator node found")
        stock, fixed = data.count(OLD), data.count(NEW)
        if stock == 0:
            state = "eMMC-first" if fixed else "no boot_targets string found"
            print(f"nearmic-uboot-guard: {path}: {state}")
            return rc
        if stock != 1:
            print(f"nearmic-uboot-guard: {path}: {stock} stock copies, not touching it")
            return 1
        os.pwrite(fd, NEW, data.index(OLD))
        os.fsync(fd)
        print(f"nearmic-uboot-guard: {path}: restored eMMC-first boot order at byte {data.index(OLD)}")
        return rc
    finally:
        os.close(fd)


def root_disk():
    src = ""
    with open("/proc/mounts") as f:
        for line in f:
            p = line.split()
            if p[1] == "/" and p[0].startswith("/dev/"):
                src = os.path.realpath(p[0])
    name = os.path.basename(src)
    parent = os.path.basename(os.path.dirname(os.path.realpath(f"/sys/class/block/{name}")))
    return f"/dev/{parent}" if parent.startswith("mmcblk") else ""


def main():
    rc = 0
    if len(sys.argv) > 1:
        for arg in sys.argv[1:]:
            path, _, limit = arg.partition(":")
            rc |= patch(path, int(limit) if limit else 0)
        return rc
    disk = root_disk()
    if disk:
        rc |= patch(disk, BOOT_AREA)
    else:
        print("nearmic-uboot-guard: root is not on an mmc disk; skipping the boot area")
    for f in glob.glob("/usr/lib/linux-u-boot-*/u-boot.itb"):
        rc |= patch(f)
    return rc


if __name__ == "__main__":
    sys.exit(main())
