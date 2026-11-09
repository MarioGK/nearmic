#!/usr/bin/env bash
# Flash the prepared Armbian image to the ROCK 4 Plus eMMC via rkdeveloptool.
# The board must already be in Maskrom mode and the SPI jumper (if any) removed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$(dirname "$SCRIPT_DIR")/work}"
IMAGE="${1:-$WORK/Armbian_26.8.1_Rockpi-4bplus_trixie_current_6.18.44_minimal.img}"
LOADER="${2:-$WORK/rk3399_loader_v1.27.126.bin}"
LOADER_URL="https://dl.radxa.com/rockpi4/images/loader/rk3399_loader_v1.27.126.bin"

command -v rkdeveloptool >/dev/null || { echo "rkdeveloptool not installed"; exit 1; }
[ -f "$IMAGE" ] || { echo "Image not found: $IMAGE (run prepare-image.sh first)"; exit 1; }
[ -f "$LOADER" ] || curl -fL --retry 3 -o "$LOADER" "$LOADER_URL"

echo "== device =="
rkdeveloptool ld

echo "== loading RK3399 loader =="
sudo rkdeveloptool db "$LOADER"
sleep 5

echo "== selecting eMMC and checking loader =="
sudo rkdeveloptool cs 1 || true
sudo rkdeveloptool rci

echo "== writing image to eMMC (LBA 0) =="
sudo rkdeveloptool wl 0 "$IMAGE"

echo
echo "IMPORTANT: remove the SPI jumper (pins 23-25) if it is still installed,"
echo "then reset the board so it boots from eMMC."
read -r -p "Press Enter to run 'rkdeveloptool rd'..." _
sudo rkdeveloptool rd
