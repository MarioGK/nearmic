#!/usr/bin/env bash
# Erase the SPI NOR flash on a ROCK 4 Plus / 4B+ so the BootROM falls through
# to the eMMC. The board must already be in Maskrom (SPI jumper 23-25 installed
# and Maskrom button held during power-up).
#
# After this completes:
#   1. power off the board
#   2. remove the 23-25 jumper
#   3. power on normally -> it should boot the eMMC Armbian image
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$(dirname "$SCRIPT_DIR")/work}"
LOADER="${1:-$WORK/rk3399_loader_spinor_v1.15.114.bin}"
LOADER_URL="https://dl.radxa.com/rockpi/images/loader/spi/rk3399_loader_spinor_v1.15.114.bin"

[ -f "$LOADER" ] || curl -fL --retry 3 -o "$LOADER" "$LOADER_URL"

echo "== maskrom device =="
sudo rkdeveloptool ld

echo "== SPI NOR loader =="
sudo rkdeveloptool db "$LOADER"
sleep 3

echo "== select SPI NOR (9) and erase =="
sudo rkdeveloptool cs 9 || true
sudo rkdeveloptool ef

echo "== reset =="
sudo rkdeveloptool rd
echo
echo "Now power off, remove the SPI jumper (pins 23-25), and power on."
