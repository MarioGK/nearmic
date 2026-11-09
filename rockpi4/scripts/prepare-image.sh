#!/usr/bin/env bash
# Prepare an Armbian 26.8.1 (Debian 13) image for ROCK 4 Plus / 4B+ (rockpi-4bplus)
# with user mariogk, SSH key, passwordless sudo and Ethernet networking.
#
# Requires: sudo, curl, xz, qemu-user-static (binfmt for aarch64), git, coreutils.
# Run from anywhere: ./prepare-image.sh
set -euo pipefail

BOARD="rockpi-4bplus"
IMAGE_XZ="Armbian_26.8.1_Rockpi-4bplus_trixie_current_6.18.44_minimal.img.xz"
IMAGE_IMG="${IMAGE_XZ%.xz}"
IMAGE_URL="https://dl.armbian.com/${BOARD}/Trixie_current_minimal"
IMAGE_SHA_URL="${IMAGE_URL}.sha"
EXPECTED_SHA="d702bbb6a4692f6afaebeba7360825c7f30714fb74b0373207dd2dd8a95e75a0"

TARGET_USER="${TARGET_USER:-mariogk}"
TARGET_KEY="${TARGET_KEY:-$HOME/.ssh/id_ed25519.pub}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$(dirname "$SCRIPT_DIR")/work}"
CREDENTIALS="$(dirname "$SCRIPT_DIR")/credentials.txt"
mkdir -p "$WORK"

cd "$WORK"
[ -f "$IMAGE_XZ" ] || curl -fL --retry 3 -o "$IMAGE_XZ" "$IMAGE_URL"
actual=$(sha256sum "$IMAGE_XZ" | awk '{print $1}')
[ "$actual" = "$EXPECTED_SHA" ] || { echo "SHA256 mismatch: $actual"; exit 1; }
[ -f "$IMAGE_IMG" ] || xz -dk "$IMAGE_XZ"

# credentials
if [ -f "$CREDENTIALS" ]; then
  USER_PASS=$(awk -F': ' '/mariogk password/{print $2}' "$CREDENTIALS")
  ROOT_PASS=$(awk -F': ' '/root password/{print $2}' "$CREDENTIALS")
fi
[ -n "${USER_PASS:-}" ] || USER_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
[ -n "${ROOT_PASS:-}" ] || ROOT_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)

ROOT="$(mktemp -d "$WORK/root.XXXXXX")"
OFFSET=$((32768 * 512))
cleanup() {
  for m in dev/pts dev proc sys; do mountpoint -q "$ROOT/$m" && sudo umount "$ROOT/$m" || true; done
  mountpoint -q "$ROOT" && sudo umount "$ROOT" || true
  rmdir "$ROOT" 2>/dev/null || true
}
trap cleanup EXIT

sudo mount -o loop,offset=$OFFSET "$IMAGE_IMG" "$ROOT"
sudo mount --bind /dev "$ROOT/dev"
sudo mount --bind /dev/pts "$ROOT/dev/pts"
sudo mount -t proc proc "$ROOT/proc"
sudo mount -t sysfs sys "$ROOT/sys"

if ! sudo chroot "$ROOT" id "$TARGET_USER" >/dev/null 2>&1; then
  sudo chroot "$ROOT" /usr/sbin/useradd -m -s /bin/bash -G sudo "$TARGET_USER"
fi
printf '%s:%s\n' "$TARGET_USER" "$USER_PASS" | sudo chroot "$ROOT" /usr/sbin/chpasswd
printf 'root:%s\n' "$ROOT_PASS" | sudo chroot "$ROOT" /usr/sbin/chpasswd
sudo chroot "$ROOT" /usr/bin/chage -M 99999 -I -1 -E -1 "$TARGET_USER"

sudo install -d -m 700 -o "$TARGET_USER" -g "$TARGET_USER" "$ROOT/home/$TARGET_USER/.ssh"
sudo install -m 600 -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_KEY" \
  "$ROOT/home/$TARGET_USER/.ssh/authorized_keys"

printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$TARGET_USER" | \
  sudo tee "$ROOT/etc/sudoers.d/90-$TARGET_USER" >/dev/null
sudo chmod 0440 "$ROOT/etc/sudoers.d/90-$TARGET_USER"

sudo tee "$ROOT/etc/ssh/sshd_config.d/99-nearmic.conf" >/dev/null <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication yes
PubkeyAuthentication yes
EOF
sudo chmod 0644 "$ROOT/etc/ssh/sshd_config.d/99-nearmic.conf"

sudo rm -f "$ROOT/root/.not_logged_in_yet"
sudo chroot "$ROOT" /usr/sbin/netplan generate >/dev/null
sudo chroot "$ROOT" /usr/sbin/visudo -cf /etc/sudoers

umask 077
printf 'mariogk password: %s\nroot password: %s\n' "$USER_PASS" "$ROOT_PASS" > "$CREDENTIALS"
chmod 600 "$CREDENTIALS"

echo "Image ready: $WORK/$IMAGE_IMG"
echo "Credentials: $CREDENTIALS"
