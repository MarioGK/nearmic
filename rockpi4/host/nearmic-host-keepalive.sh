#!/bin/sh
# Keep the NearMic USB microphone streaming on the host computer.
#
# Without this the host's PipeWire/WirePlumber suspends the UAC2 capture node
# after a few seconds of silence. Opening the microphone then has to resume the
# node, re-enable the USB alternate setting and restart the board's DSP chain,
# which is heard as a lag between starting to talk and the microphone working.
#
# Holding one silent consumer open keeps the whole chain hot: the first word is
# already on the wire. It costs one 48 kHz mono stream that is discarded.
set -u

while :; do
	src="$(pw-dump 2>/dev/null | sed -n 's/.*"node.name": "\(alsa_input\.usb-NearMic[^"]*mono-fallback\)".*/\1/p' | head -n1)"
	if [ -n "$src" ]; then
		pw-cat --record --raw --rate=48000 --channels=1 --format=s16 \
			--target "$src" - >/dev/null 2>&1
	fi
	sleep 2
done
