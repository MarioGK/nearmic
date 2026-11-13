#!/usr/bin/env bash
# Build a self-provisioning Armbian 26.8.1 (Debian 13) image for the
# ROCK 4 Plus / 4B+ (rockpi-4bplus) NearMic appliance.
#
# The flashed board needs no SSH session to become a microphone:
#   - user mariogk, SSH key, passwordless sudo
#   - Wi-Fi from rockpi4/.env (WIFI_SSID, WIFI_PASS, WIFI_COUNTRY) on any USB
#     adapter, renamed to wlan0; Ethernet DHCP is kept as well
#   - TP-Link USB Wi-Fi: in-kernel rtw88/rtw89/rtl8xxxu/mt76/ath9k_htc drivers,
#     armbian-firmware-full, usb-modeswitch for adapters that start as a driver CD
#   - mDNS (rockpi-4bplus.local) and the DHCP hostname, so it is found on any IP
#   - PipeWire/WirePlumber and the appliance packages preinstalled
#   - NearMic binary, OTG overlay (user_overlays=nearmic-otg) and the rockpi4
#     tree in /opt/nearmic; nearmic-firstboot.service runs
#     apply-appliance.sh --apply once on the first boot
#   - fsck.repair=yes so an unclean power cut never stops the boot at a prompt
#
# Requires: sudo, curl, xz, qemu-user-static (binfmt for aarch64), sfdisk,
# e2fsprogs, rsync, llvm-strip (optional).
# Usage: ./prepare-image.sh            -> rockpi4/work/nearmic-<date>.img
set -euo pipefail

BOARD="rockpi-4bplus"
IMAGE_XZ="Armbian_26.8.1_Rockpi-4bplus_trixie_current_6.18.44_minimal.img.xz"
IMAGE_URL="https://dl.armbian.com/${BOARD}/Trixie_current_minimal"
EXPECTED_SHA="d702bbb6a4692f6afaebeba7360825c7f30714fb74b0373207dd2dd8a95e75a0"
GROW="${GROW:-4G}"

TARGET_USER="${TARGET_USER:-mariogk}"
TARGET_KEY="${TARGET_KEY:-$HOME/.ssh/id_ed25519.pub}"
MIC_SOURCE="${MIC_SOURCE:-alsa_input.usb-Maono_ProStudio_2x2_Lite_Maono_ProStudio_2x2_Lite-00.analog-stereo}"
PACKAGES=(pipewire wireplumber pipewire-audio alsa-utils unattended-upgrades needrestart
	avahi-daemon libnss-mdns usb-modeswitch usb-modeswitch-data rfkill iputils-ping u-boot-tools)
# armbian-firmware-full replaces armbian-firmware: every Wi-Fi blob Armbian
# ships (rtw88/rtw89 incl. RTL8851B/8852B/C, mt76 incl. MT7921/7925, ath, aic8800),
# so whichever TP-Link adapter is plugged in finds its firmware. It unpacks to
# 1.9 GB, hence GROW=4G.
FULL_FIRMWARE="${FULL_FIRMWARE:-1}"
UPGRADE="${UPGRADE:-1}"   # apt full-upgrade inside the image (kernel held)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE="$(dirname "$SCRIPT_DIR")"     # rockpi4/
REPO="$(dirname "$TREE")"
WORK="${WORK:-$TREE/work}"
CREDENTIALS="$TREE/credentials.txt"
ENV_FILE="${ENV_FILE:-$TREE/.env}"
BINARY="${NEARMIC_BINARY:-$REPO/zig-out/bin/nearmic}"
OUT="${OUT:-$WORK/nearmic-$(date +%Y%m%d).img}"
mkdir -p "$WORK"

[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE (WIFI_SSID, WIFI_PASS, WIFI_COUNTRY)"; exit 1; }
# shellcheck disable=SC1090
. "$ENV_FILE"
: "${WIFI_SSID:?set WIFI_SSID in $ENV_FILE}" "${WIFI_PASS:?set WIFI_PASS in $ENV_FILE}"
WIFI_COUNTRY="${WIFI_COUNTRY:-BR}"
[ -s "$BINARY" ] || { echo "missing NearMic binary $BINARY (zig build -Dtarget=aarch64-linux-gnu ...)"; exit 1; }
file -b "$BINARY" | grep -q aarch64 || { echo "$BINARY is not an aarch64 binary"; exit 1; }

cd "$WORK"
if [ ! -f "$IMAGE_XZ" ] && [ -f armbian.img.xz ]; then ln -sf armbian.img.xz "$IMAGE_XZ"; fi
[ -f "$IMAGE_XZ" ] || curl -fL --retry 3 -o "$IMAGE_XZ" "$IMAGE_URL"
actual=$(sha256sum "$IMAGE_XZ" | awk '{print $1}')
[ "$actual" = "$EXPECTED_SHA" ] || { echo "SHA256 mismatch: $actual"; exit 1; }
echo "== unpacking a fresh copy to $OUT"
xz -dc "$IMAGE_XZ" >"$OUT"
truncate -s "+$GROW" "$OUT"
echo ', +' | sfdisk -q -N 1 "$OUT"

# U-Boot 2022.07 in this image tries USB before the eMMC (boot_targets=usb0
# mmc1 mmc0 ...). `usb start` then powers and enumerates whatever sits on the
# host ports, and with the Wi-Fi adapter (which first shows up as a driver CD,
# i.e. USB storage) or the audio interface plugged in the board never reached
# Linux. The default environment is plain text inside u-boot.itb and the FIT
# is not hash-checked (SPL_FIT_SIGNATURE is off), so reorder it in place:
# SD card, eMMC, NVMe, and USB only when nothing else boots.
patch_uboot() { # file [limit-bytes]
	python3 -I - "$1" "${2:-0}" <<'PY'
import sys
path, limit = sys.argv[1], int(sys.argv[2])
old = b"boot_targets=usb0 mmc1 mmc0 nvme0 pxe dhcp sf0 "
new = b"boot_targets=mmc1 mmc0 nvme0 usb0 pxe dhcp sf0 "
assert len(old) == len(new)
with open(path, "r+b") as f:
    data = f.read(limit) if limit else f.read()
    n = data.count(old)
    if n == 0 and data.count(new) >= 1:
        print(f"u-boot boot order already patched: {path}"); sys.exit(0)
    if n != 1:
        sys.exit(f"expected one boot_targets string in {path}, found {n}")
    f.seek(data.index(old)); f.write(new)
    print(f"u-boot boot order patched at byte {data.index(old)}: {path}")
PY
}
# Boot area = everything before the first partition (16 MiB).
patch_uboot "$OUT" $((32768 * 512))

# credentials (local, git-ignored)
if [ -f "$CREDENTIALS" ]; then
	USER_PASS=$(awk -F': ' '/mariogk password/{print $2}' "$CREDENTIALS")
	ROOT_PASS=$(awk -F': ' '/root password/{print $2}' "$CREDENTIALS")
fi
[ -n "${USER_PASS:-}" ] || USER_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
[ -n "${ROOT_PASS:-}" ] || ROOT_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)

LOOP="$(sudo losetup -fP --show "$OUT")"
ROOT="$(mktemp -d "$WORK/root.XXXXXX")"
cleanup() {
	sudo rm -f "$ROOT/usr/sbin/policy-rc.d" 2>/dev/null || true
	if [ -L "$ROOT/etc/resolv.conf.nearmic" ] || [ -e "$ROOT/etc/resolv.conf.nearmic" ]; then
		sudo mv -f "$ROOT/etc/resolv.conf.nearmic" "$ROOT/etc/resolv.conf"
	fi
	for m in dev/pts dev proc sys; do mountpoint -q "$ROOT/$m" && sudo umount -l "$ROOT/$m" || true; done
	mountpoint -q "$ROOT" && sudo umount -l "$ROOT" || true
	sudo losetup -d "$LOOP" 2>/dev/null || true
	rmdir "$ROOT" 2>/dev/null || true
}
trap cleanup EXIT

sudo e2fsck -pf "${LOOP}p1" >/dev/null
sudo resize2fs -p "${LOOP}p1" >/dev/null
sudo mount "${LOOP}p1" "$ROOT"
sudo mount --bind /dev "$ROOT/dev"
sudo mount --bind /dev/pts "$ROOT/dev/pts"
sudo mount -t proc proc "$ROOT/proc"
sudo mount -t sysfs sys "$ROOT/sys"
in_root() { sudo chroot "$ROOT" "$@"; }

echo "== packages"
sudo mv "$ROOT/etc/resolv.conf" "$ROOT/etc/resolv.conf.nearmic"
# The workstation may only list the systemd-resolved stub (127.0.0.53), which
# does not exist inside the chroot.
printf 'nameserver %s\n' 10.10.10.1 1.1.1.1 | sudo tee "$ROOT/etc/resolv.conf" >/dev/null
printf '#!/bin/sh\nexit 101\n' | sudo tee "$ROOT/usr/sbin/policy-rc.d" >/dev/null
sudo chmod 0755 "$ROOT/usr/sbin/policy-rc.d"
in_root env DEBIAN_FRONTEND=noninteractive apt-get update -q
# The kernel, device trees and U-Boot stay at the versions this image was
# boot-tested with; unattended-upgrades moves them later, when the board is
# reachable. Everything else is brought up to date now.
KERNEL_PKGS=$(in_root dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-image-*' 'linux-dtb-*' 'linux-u-boot-*' 2>/dev/null | awk '$1 == "ii" {printf "%s ", $2}')
if [ "$UPGRADE" = 1 ]; then
	# shellcheck disable=SC2086
	in_root apt-mark hold $KERNEL_PKGS >/dev/null
	in_root env DEBIAN_FRONTEND=noninteractive apt-get -y -q \
		-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
	# shellcheck disable=SC2086
	in_root apt-mark unhold $KERNEL_PKGS >/dev/null
fi
in_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${PACKAGES[@]}"
in_root apt-get clean
if [ "$FULL_FIRMWARE" = 1 ]; then
	# Swapping the firmware package removes armbian-firmware first, so a
	# failure here must stop the build rather than ship an image without it.
	in_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends armbian-firmware-full
	in_root apt-get clean
fi
sudo rm -f "$ROOT/usr/sbin/policy-rc.d"
sudo rm -f "$ROOT/etc/resolv.conf"
sudo mv "$ROOT/etc/resolv.conf.nearmic" "$ROOT/etc/resolv.conf"

echo "== user"
if ! in_root id "$TARGET_USER" >/dev/null 2>&1; then
	in_root /usr/sbin/useradd -m -s /bin/bash -G sudo,audio "$TARGET_USER"
fi
in_root /usr/sbin/usermod -aG sudo,audio "$TARGET_USER"
printf '%s:%s\n' "$TARGET_USER" "$USER_PASS" | in_root /usr/sbin/chpasswd
printf 'root:%s\n' "$ROOT_PASS" | in_root /usr/sbin/chpasswd
in_root /usr/bin/chage -M 99999 -I -1 -E -1 "$TARGET_USER"
HOME_DIR="$ROOT/home/$TARGET_USER"
UGID="$(in_root id -u "$TARGET_USER"):$(in_root id -g "$TARGET_USER")"
sudo install -d -m 700 -o "${UGID%%:*}" -g "${UGID##*:}" "$HOME_DIR/.ssh"
sudo install -m 600 -o "${UGID%%:*}" -g "${UGID##*:}" "$TARGET_KEY" "$HOME_DIR/.ssh/authorized_keys"
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$TARGET_USER" | sudo tee "$ROOT/etc/sudoers.d/90-$TARGET_USER" >/dev/null
sudo chmod 0440 "$ROOT/etc/sudoers.d/90-$TARGET_USER"
in_root /usr/sbin/visudo -cf /etc/sudoers >/dev/null
sudo tee "$ROOT/etc/ssh/sshd_config.d/99-nearmic.conf" >/dev/null <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication yes
PubkeyAuthentication yes
EOF
# Skip Armbian's interactive first-login wizard.
sudo rm -f "$ROOT/root/.not_logged_in_yet"

echo "== network (Wi-Fi $WIFI_SSID, country $WIFI_COUNTRY)"
sudo install -m 0644 "$TREE/network/10-nearmic-usb-wifi.link" "$ROOT/etc/systemd/network/10-nearmic-usb-wifi.link"
sudo install -m 0644 "$TREE/udev/70-nearmic-wifi.rules" "$ROOT/etc/udev/rules.d/70-nearmic-wifi.rules"
printf 'options cfg80211 ieee80211_regdom=%s\n' "$WIFI_COUNTRY" | sudo tee "$ROOT/etc/modprobe.d/nearmic-wifi.conf" >/dev/null
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
sudo install -m 0600 /dev/null "$ROOT/etc/netplan/20-nearmic-wifi.yaml"
sudo tee "$ROOT/etc/netplan/20-nearmic-wifi.yaml" >/dev/null <<EOF
# Generated by rockpi4/scripts/prepare-image.sh from rockpi4/.env.
network:
  version: 2
  renderer: networkd
  wifis:
    wlan0:
      optional: true
      dhcp4: true
      dhcp6: true
      regulatory-domain: "$WIFI_COUNTRY"
      access-points:
        "$(esc "$WIFI_SSID")":
          password: "$(esc "$WIFI_PASS")"
EOF
# Do not hold the boot for 2 minutes waiting for a link that is not plugged.
sudo sed -i 's/^\(\s*\)dhcp4: yes$/\1dhcp4: yes\n\1optional: true/' "$ROOT/etc/netplan/10-dhcp-all-interfaces.yaml"
sudo chmod 0600 "$ROOT"/etc/netplan/*.yaml
in_root /usr/sbin/netplan generate
in_root systemctl enable avahi-daemon.service systemd-networkd.service >/dev/null 2>&1 || true
# Same timezone as the workstation, so the 04:00 maintenance reboot is 04:00
# local time and not 04:00 UTC.
TZ_NAME="${TZ_NAME:-$(timedatectl show -p Timezone --value 2>/dev/null || echo Etc/UTC)}"
if [ -e "$ROOT/usr/share/zoneinfo/$TZ_NAME" ]; then
	sudo ln -sfn "/usr/share/zoneinfo/$TZ_NAME" "$ROOT/etc/localtime"
	echo "$TZ_NAME" | sudo tee "$ROOT/etc/timezone" >/dev/null
fi

for f in "$ROOT"/usr/lib/linux-u-boot-*/u-boot.itb; do
	[ -f "$f" ] && sudo bash -c "$(declare -f patch_uboot); patch_uboot '$f'"
done
# Bootloader guard on the image (boot order; the USB-power patch inside it is
# opt-in and stays off, see nearmic-uboot-guard.py).
sudo python3 -I "$TREE/scripts/nearmic-uboot-guard.py" "$LOOP:$((32768 * 512))" "$ROOT"/usr/lib/linux-u-boot-*/u-boot.itb

# First boot stage: Rockchip's DDR init blob instead of U-Boot's open-source
# TPL. With Armbian's stock idbloader (U-Boot TPL) this board hung before Linux
# on many power-ups and resets (2026-11-10/11); with the blob in front of the
# same SPL and U-Boot it passed 10 reboots and 5 forced resets in a row with
# the Wi-Fi adapter and the Maono attached. This is Armbian's own
# "tpl-blob" layout: mkimage -T rksd -d <ddr blob>:<u-boot-spl.bin>.
DDR_BLOB="$WORK/rk3399_ddr_800MHz_v1.30.bin"
DDR_URL="https://github.com/rockchip-linux/rkbin/raw/master/bin/rk33/rk3399_ddr_800MHz_v1.30.bin"
DDR_SHA="2c74f7c0a2f7b1a49225fd0dca2fd88f574177e2b87dd4c526d569a94a9bcd92"
[ -f "$DDR_BLOB" ] || curl -fL --retry 3 -o "$DDR_BLOB" "$DDR_URL"
[ "$(sha256sum "$DDR_BLOB" | awk '{print $1}')" = "$DDR_SHA" ] || { echo "DDR blob SHA256 mismatch"; exit 1; }
SPL="$(ls "$ROOT"/usr/lib/linux-u-boot-*/u-boot-spl.bin | head -n1)"
sudo install -D -m 0644 "$DDR_BLOB" "$ROOT/usr/local/share/nearmic/boot/rk3399_ddr.bin"
in_root mkimage -n rk3399 -T rksd -d "/usr/local/share/nearmic/boot/rk3399_ddr.bin:${SPL#"$ROOT"}" \
	/usr/local/share/nearmic/boot/idbloader.img >/dev/null
IDB="$ROOT/usr/local/share/nearmic/boot/idbloader.img"
[ "$(stat -c %s "$IDB")" -lt $(( (16384 - 64) * 512 )) ] || { echo "idbloader too large"; exit 1; }
sudo dd if=/dev/zero of="$LOOP" bs=512 seek=64 count=$((16384 - 64)) conv=notrunc status=none
sudo dd if="$IDB" of="$LOOP" bs=512 seek=64 conv=notrunc,fsync status=none
echo "idbloader: Rockchip DDR blob v1.30 + $(basename "$(dirname "$SPL")") SPL"

echo "== boot: OTG overlay, fsck repair"
ENV="$ROOT/boot/armbianEnv.txt"
sudo install -d "$ROOT/boot/overlay-user"
sudo install -m 0644 "$TREE/dtb/nearmic-otg.dtbo" "$ROOT/boot/overlay-user/nearmic-otg.dtbo"
sudo grep -q '^user_overlays=' "$ENV" || echo 'user_overlays=nearmic-otg' | sudo tee -a "$ENV" >/dev/null
sudo grep -q '^extraargs=' "$ENV" || echo 'extraargs=fsck.repair=yes panic=10 rt_group_sched=0' | sudo tee -a "$ENV" >/dev/null
sudo cp -a "$ENV" "$ENV.nearmic.bak"

echo "== NearMic"
sudo rsync -a --delete --exclude work --exclude credentials.txt --exclude .env "$TREE/" "$ROOT/opt/nearmic/"
sudo install -d "$ROOT/opt/nearmic/bin"
sudo install -m 0755 "$BINARY" "$ROOT/opt/nearmic/bin/nearmic"
command -v llvm-strip >/dev/null && sudo llvm-strip "$ROOT/opt/nearmic/bin/nearmic"
# 10 s speech clip for nearmic-engine-guard.sh (DeepFilterNet realtime check).
GUARD_CLIP="${GUARD_CLIP:-$WORK/guard-clip.wav}"
[ -f "$GUARD_CLIP" ] && sudo install -m 0644 "$GUARD_CLIP" "$ROOT/opt/nearmic/bin/guard-clip.wav"
sudo chown -R root:root "$ROOT/opt/nearmic"
sudo install -d -o "${UGID%%:*}" -g "${UGID##*:}" "$HOME_DIR/.config" "$HOME_DIR/.config/nearmic"
sed "s|^source = \"\"|source = \"$MIC_SOURCE\"|" "$TREE/config/nearmic-config.toml" |
	sudo install -m 0644 -o "${UGID%%:*}" -g "${UGID##*:}" /dev/stdin "$HOME_DIR/.config/nearmic/config.toml"
sudo install -m 0644 "$TREE/systemd/nearmic-firstboot.service" "$ROOT/etc/systemd/system/nearmic-firstboot.service"
in_root systemctl enable nearmic-firstboot.service

echo "== always-on: USB gadget, USB maintenance link, CPU policy, persistent logs"
# These must not depend on first-boot provisioning: if it fails, the board is
# still a USB microphone with SSH over the same cable (ssh mariogk@192.168.77.1).
sudo install -m 0755 "$TREE/scripts/setup-uac2-gadget.sh" "$ROOT/usr/local/sbin/nearmic-gadget-setup"
sudo install -m 0644 "$TREE/systemd/nearmic-gadget.service" "$ROOT/etc/systemd/system/nearmic-gadget.service"
sudo install -m 0644 "$TREE/systemd/nearmic-cpufreq.service" "$ROOT/etc/systemd/system/nearmic-cpufreq.service"
sudo install -m 0644 "$TREE/network/30-nearmic-usb0.network" "$ROOT/etc/systemd/network/30-nearmic-usb0.network"
sudo install -m 0755 "$TREE/scripts/nearmic-wifi-watchdog.sh" "$ROOT/usr/local/sbin/nearmic-wifi-watchdog"
sudo install -m 0644 "$TREE/systemd/nearmic-wifi-watchdog.service" "$TREE/systemd/nearmic-wifi-watchdog.timer" "$ROOT/etc/systemd/system/"
sudo install -m 0644 "$TREE/config/99-nearmic-sysctl.conf" "$ROOT/etc/sysctl.d/99-nearmic.conf"
sudo install -m 0644 "$TREE/systemd/watchdog.conf" -D "$ROOT/etc/systemd/system.conf.d/99-nearmic-watchdog.conf"
in_root systemctl enable nearmic-gadget.service nearmic-cpufreq.service nearmic-wifi-watchdog.timer
# Armbian keeps /var/log in a 50 MB RAM disk; a hang or brownout loses it.
sudo sed -i 's/^ENABLED=.*/ENABLED=false/' "$ROOT/etc/default/armbian-ramlog"
sudo install -d "$ROOT/etc/systemd/journald.conf.d" "$ROOT/var/log/journal"
printf '[Journal]\nStorage=persistent\nSystemMaxUse=200M\n' | sudo tee "$ROOT/etc/systemd/journald.conf.d/99-nearmic.conf" >/dev/null

umask 077
printf 'mariogk password: %s\nroot password: %s\n' "$USER_PASS" "$ROOT_PASS" >"$CREDENTIALS"
chmod 600 "$CREDENTIALS"

sync
echo "Image ready: $OUT"
echo "Flash: rockpi4/scripts/rk.sh flash $OUT"
