---
name: rockpi-flash
description: Flash, back up, verify or recover the NearMic ROCK 4 Plus (RK3399) eMMC over Mask ROM with rkdeveloptool. Use when the board does not boot, needs a new image, or must be inspected without network.
---

# Flash the ROCK 4 Plus eMMC (Mask ROM)

Follows Radxa's official procedure
(https://docs.radxa.com/en/rock4/rock4ab-se/low-level-dev/maskrom/linux):
`rkdeveloptool db <loader>` -> `wl 0 <image>` -> `rd`, with the board in
Mask ROM over the USB-A-to-A cable on the upper USB 3.0 (OTG) port.
Everything below is scripted in `rockpi4/scripts/rk.sh`.

## Rules learned the hard way (2026-11-10)

1. **Loader: `rockpi4/work/rk3399_loader_v1.30.130.bin`.** v1.27.126 writes
   correctly but every *read* past LBA 65536 (32 MiB) returns `0xCC` filler,
   which looks like eMMC corruption and is not.
2. **Upload the loader once per power-on.** A second `db` on the same Mask ROM
   enumeration wedges the USB link; only a power cycle clears it.
3. **`rkdeveloptool rd 3` reboots straight back into Mask ROM** (no button).
   Use it to retry with another loader instead of asking for a button press.
4. **Power:** board on its own 5 V/3 A supply, nothing else on its USB ports
   while flashing (Wi-Fi + Maono load browned it out). Tape over VBUS (pin 1)
   on the A-to-A plug or use a USB power blocker: the host's 5 V otherwise
   back-feeds the board. 2026-11-11: a plain A-to-A cable without tape worked
   with a UGREEN 65 W charger, with the Wi-Fi adapter and Maono unplugged.
5. Success = `lsusb` shows `1209:4e4d` (NearMic gadget). For the boot after
   `wl` + `rd`, see rule 9.
6. Check boot evidence offline: partition 1 starts at sector 32768 (byte
   16 MiB), so the ext4 superblock is at byte `32768*512 + 1024`.
   `Mount count` / `Last mount time` show whether Linux ever ran.

## Rules from 2026-11-11

7. **No SPI jumper is needed on this board.** Radxa's doc says to connect the
   SPI flash pins to GND (jumper pins 23-25 on the 40-pin header) before
   entering Mask ROM when the board has SPI flash. The SPI NOR was erased on
   2026-11-09 (`rockpi4/scripts/erase-spi.sh`), so the boot ROM falls through
   to the eMMC and Mask ROM is reached with the button alone. Put the jumper
   back only if SPI holds a bootloader again, and remove it for normal boot.
8. **Enter Mask ROM (the one physical step for the user):** unplug every USB
   device from the host ports (Wi-Fi adapter, audio interface), keep the
   USB-A-to-A cable in the upper USB 3.0 port, hold the Mask ROM button, plug
   in power, count to 3, release. Success = `lsusb` shows `2207:330c`.
9. **`rkdeveloptool rd` (software reset) booted Linux by itself on 2026-11-11**
   (first boot about 25 s to the gadget). Earlier flashes did not reliably
   start Linux. Wait 3 min for `1209:4e4d`; if it does not appear, do one cold
   power cycle with no button held. A cold power cycle with the Wi-Fi adapter
   and Maono attached is **not tested yet**.
10. **Diagnose a board that does not boot:** blue LED heartbeat = Linux kernel
    running. Solid green only = stuck before Linux (boot ROM or U-Boot). U-Boot
    prints on HDMI and on UART2 at 1500000 baud.
11. **Boot-order root cause (most likely; fixed in the image builder):**
    Armbian's U-Boot 2022.07 has `boot_targets=usb0 mmc1 mmc0 nvme0 ...`, so it
    runs `usb start` and tries USB before the eMMC. With the TP-Link Wi-Fi
    adapter (first enumerates as a USB-storage driver CD) or the Maono interface
    plugged in, the board never reached Linux; with nothing plugged in it did.
    `prepare-image.sh` patches the default environment inside `u-boot.itb` to
    `boot_targets=mmc1 mmc0 nvme0 usb0 ...` (same length; the FIT is not
    hash-checked because `SPL_FIT_SIGNATURE` is off). U-Boot's environment would
    live in SPI at 0x3F8000, which is erased, so the built-in default runs.
    Flash only patched images.
12. **Reach the board without Wi-Fi or Ethernet** over the same A-to-A cable
    after a good boot:
    - USB audio `1209:4e4d`.
    - CDC-NCM link: board `192.168.77.1`, host gets an address by DHCP. If the
      host runs no DHCP on it: `sudo ip addr add 192.168.77.2/24 dev <iface>`,
      where `<iface>` is the host interface with MAC `02:4e:4d:00:00:02` (see
      `ip -br link`); then `ssh mariogk@192.168.77.1`.
    - No serial console: CDC-ACM does not bind together with UAC2 + NCM (`-19`),
      so no `/dev/ttyACM*` appears on the host.
    - Over Wi-Fi: `ssh mariogk@rockpi-4bplus.local` (mDNS).
13. **Offline checks on a read-back or image, read-only only.** Run `dumpe2fs`
    first, then mount, because a mount can change the fields you read:
    ```sh
    LOOP=$(sudo losetup -fP --show -r IMG)
    sudo dumpe2fs -h "${LOOP}p1" | grep -E 'Mount count|Last mount time'
    sudo mkdir -p /mnt/nearmic-ro
    sudo mount -o ro,noload "${LOOP}p1" /mnt/nearmic-ro
    # inspect /mnt/nearmic-ro/...
    sudo umount /mnt/nearmic-ro && sudo losetup -d "$LOOP"
    ```
    Always `umount` and `losetup -d` afterwards, even on error.
14. **Loader timing (`rk.sh`, changed 2026-11-11).** `rk.sh` waits 8 s after the
    Mask ROM device appears, then runs `db`. A loader uploaded 3 s after power-on
    reported success and never started. After `db`, `rk.sh` polls `rfi` for up
    to 24 s. If it still does not answer, power-cycle with the button and unplug
    every host-port device first.
15. **Size and time.** The image is 5.8 GB. `wl` took 4 min 45 s and the
    read-back verify about 3 min. The verify copy goes to `rockpi4/work/rk-verify.*`,
    not `/tmp` (the tmpfs filled up), so `rockpi4/work/` needs room for two
    5.8 GB files.

## Troubleshooting table

| Symptom | Cause | Fix |
| --- | --- | --- |
| `2207:330c` never appears in `lsusb` | Button not held through power-up, or devices on the host ports | Rule 8: unplug host-port devices, hold button, power, count 3, release |
| Solid green LED, no blue heartbeat, no `1209:4e4d` | Stuck before Linux (boot ROM or U-Boot) | Flash a patched image (rule 11); check UART2 at 1500000 baud |
| Boots with nothing plugged in, not with Wi-Fi or Maono | U-Boot runs `usb start` before the eMMC | `strings` must show `boot_targets=mmc1 mmc0`; reflash the patched image |
| Flash verified, board silent after `rd` | Software reset not started Linux yet | Wait 3 min; then one cold power cycle, no button (rule 9) |
| `loader uploaded but not answering after 24 s` | Loader did not start on this power-on | Power-cycle with the button, host-port devices unplugged (rule 14) |
| Second `db` hangs, or `rfi` stops answering | Loader already uploaded on this power-on | Power-cycle with the button (rule 2); do not retry `db` |
| Reads past 32 MiB return `0xCC` | Loader v1.27.126 | Use v1.30.130 (the `rk.sh` default); not eMMC corruption |

## Commands

```sh
rockpi4/scripts/rk.sh wait            # block until Mask ROM, upload loader, verify
rockpi4/scripts/rk.sh flash IMG       # wait + write + verify + reset
rockpi4/scripts/rk.sh backup OUT [MB] # wait + read first MB (default: whole image size)
rockpi4/scripts/rk.sh stress [IMG]    # wait + full read compared to IMG (default: newest nearmic-*.img)
rockpi4/scripts/rk.sh maskrom         # loader already up: reboot into Mask ROM (rd 3)
```

Run `flash`/`stress` with Bash `run_in_background`, then tell the user the
one physical step from rule 8. Building the image: see the `rockpi-image` skill.
