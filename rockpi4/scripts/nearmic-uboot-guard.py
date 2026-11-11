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
"""
import glob
import os
import sys

OLD = b"boot_targets=usb0 mmc1 mmc0 nvme0 pxe dhcp sf0 "
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
        stock, fixed = data.count(OLD), data.count(NEW)
        if stock == 0:
            state = "eMMC-first" if fixed else "no boot_targets string found"
            print(f"nearmic-uboot-guard: {path}: {state}")
            return 0
        if stock != 1:
            print(f"nearmic-uboot-guard: {path}: {stock} stock copies, not touching it")
            return 1
        os.pwrite(fd, NEW, data.index(OLD))
        os.fsync(fd)
        print(f"nearmic-uboot-guard: {path}: restored eMMC-first boot order at byte {data.index(OLD)}")
        return 0
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
