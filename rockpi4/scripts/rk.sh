#!/usr/bin/env bash
# Mask ROM helper for the ROCK 4 Plus (RK3399) eMMC, after Radxa's procedure:
#   rkdeveloptool db <loader>; rkdeveloptool wl 0 <image>; rkdeveloptool rd
#
#   rk.sh wait               wait for Mask ROM, upload the loader once, verify
#   rk.sh flash IMG          wait, write IMG at LBA 0, read back + compare, reset
#   rk.sh backup OUT [MB]    wait, read the first MB MiB (default 4096) to OUT
#   rk.sh stress [IMG]       wait, read IMG's size back and compare with IMG
#   rk.sh maskrom            loader is up: reboot into Mask ROM (rd 3)
#
# Loader v1.30.130 on purpose: v1.27.126 cannot read past 32 MiB.
set -euo pipefail

TREE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$TREE/work}"
LOADER="${LOADER:-$WORK/rk3399_loader_v1.30.130.bin}"
LOADER_URL="https://dl.radxa.com/rockpi4/images/loader/rk3399_loader_v1.30.130.bin"
WAIT_S="${WAIT_S:-3600}"
RK="sudo rkdeveloptool"

log() { echo "$(date +%T) rk: $*"; }
die() { log "FAIL $*"; exit 1; }

maskrom_dev() { lsusb | awk '/2207:330c/{print $4}'; }

wait_loader() {
	command -v rkdeveloptool >/dev/null || die "install rkdeveloptool (AUR: rkdeveloptool)"
	[ -f "$LOADER" ] || curl -fL --retry 3 -o "$LOADER" "$LOADER_URL"
	# A device that already answers rfi has a loader running: reuse it.
	if [ -n "$(maskrom_dev)" ] && timeout 10 $RK rfi 2>/dev/null | grep -q "Flash Size"; then
		log "loader already running"
		return
	fi
	local skip="${SKIP_DEV:-}" dev="" t=0
	log "waiting for Mask ROM (hold the button, plug in power, release after 3 s)"
	while [ $t -lt "$WAIT_S" ]; do
		dev="$(maskrom_dev)"
		[ -n "$dev" ] && [ "$dev" != "$skip" ] && break
		dev=""; sleep 2; t=$((t + 2))
	done
	[ -n "$dev" ] || die "no Mask ROM device within ${WAIT_S}s"
	# Let power and enumeration settle: a loader uploaded in the first seconds
	# after power-on has reported "succeeded" and then never started.
	sleep "${SETTLE_S:-8}"
	[ "$(maskrom_dev)" = "$dev" ] || die "Mask ROM device changed while settling (flapping power or cable)"
	log "Mask ROM on usb dev ${dev%:}"
	timeout 30 $RK db "$LOADER" 2>&1 | grep -q succeeded ||
		die "loader upload failed (power-cycle with the button; do not retry db on the same power-on)"
	local up=0 i
	for i in 1 2 3 4 5 6; do
		sleep 4
		if timeout 10 $RK rfi 2>/dev/null | grep -q "Flash Size"; then up=1; break; fi
	done
	[ $up = 1 ] || die "loader uploaded but not answering after 24 s (power-cycle with the button; unplug every USB device from the board first)"
	log "loader up: $($RK rfi 2>&1 | awk '/Flash Size/{print $3,$4; exit}')"
}

read_back() { # out sectors
	timeout 1200 $RK rl 0 "$2" "$1" >/dev/null 2>&1 || die "read stopped at $(stat -c %s "$1" 2>/dev/null || echo 0) bytes"
	sudo chown "$USER" "$1"
}

case "${1:-}" in
wait) wait_loader ;;
flash)
	img="${2:?usage: rk.sh flash IMG}"
	[ -f "$img" ] || die "no image $img"
	sect=$(( ($(stat -c %s "$img") + 511) / 512 ))
	wait_loader
	log "writing $(basename "$img") ($((sect / 2048)) MiB)"
	timeout 1800 $RK wl 0 "$img" 2>&1 | tr '\r' '\n' | grep -q "100%" || die "write did not reach 100%"
	log "verifying"
	tmp="$(mktemp "$WORK/rk-verify.XXXXXX")"
	read_back "$tmp" "$sect"
	cmp -s "$tmp" "$img" || { rm -f "$tmp"; die "read-back differs from the image"; }
	rm -f "$tmp"
	log "verified; resetting"
	$RK rd >/dev/null
	log "DONE: cold power-cycle if 1209:4e4d does not appear within 3 min"
	;;
backup)
	out="${2:?usage: rk.sh backup OUT [MB]}"
	wait_loader
	read_back "$out" $(( ${3:-4096} * 2048 ))
	log "DONE: $(stat -c %s "$out") bytes in $out"
	;;
stress)
	img="${2:-$(ls -t "$WORK"/nearmic-*.img 2>/dev/null | head -1)}"
	[ -f "$img" ] || die "no image to compare"
	wait_loader
	tmp="$(mktemp "$WORK/rk-stress.XXXXXX")"
	start=$(date +%s)
	read_back "$tmp" $(( ($(stat -c %s "$img") + 511) / 512 ))
	if cmp -s "$tmp" "$img"; then log "PASS $(( $(stat -c %s "$img") >> 20 )) MiB in $(( $(date +%s) - start )) s"; rm -f "$tmp"
	else rm -f "$tmp"; die "data differs from $img"; fi
	;;
maskrom) $RK rd 3 && log "rebooting into Mask ROM" ;;
*) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
