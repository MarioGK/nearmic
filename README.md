# NearMic

A Linux virtual microphone for a voice that is too far from the mic. NearMic is one executable. It reads the microphone you choose, makes the voice louder and steadier, lowers stationary noise, and publishes a PipeWire source named **NearMic**. Discord, OBS, and the browser can select that source.

The processing that ships was chosen by a bake-off on a shared far-mic fixture, not by habit. The winner is the Zig chain called `dsp`: an 80 Hz high-pass, a causal spectral denoiser, a 3.5 kHz presence shelf, a speech-gated leveler aimed at about -18 dBFS, and a soft limiter. On the machine that ran the bake-off it used well under 1% of the whole CPU while keeping up with 48 kHz, and each 5.3 ms block finished in a few hundredths of a millisecond. Numbers are in [bench/RESULTS.md](bench/RESULTS.md).

A heavier dereverb stage shortened the room tail a bit more and also pulled speech level down, so it did not pass. SpeexDSP's denoise and dereverb stayed fast and did not keep pauses quiet. RNNoise, LocalVQE, DPDFNet, and ClearerVoice are discussed in [bench/EXTERNAL.md](bench/EXTERNAL.md). They are not inside the binary.

## Run

PipeWire and WirePlumber need to be running. Build with Zig 0.14.1:

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/nearmic
```

Pick **NearMic** as the input. Turn off the noise suppressor in Discord or the browser so two denoisers do not fight. Ctrl-C removes the source.

```sh
nearmic status
nearmic mode bypass          # raw voice, same delay
nearmic mode mute
nearmic mode suppress
nearmic listen on            # headphones. speakers will feed the mic
nearmic doctor
nearmic enhance in.wav out.wav
nearmic quit
```

`enhance` reads and writes 48 kHz WAV. Stereo input is mixed to mono.

Optional config at `~/.config/nearmic/config`:

```
source=alsa_input.usb-Comica_VM40
mode=suppress
listen=off
```

`source` is the PipeWire node name of the real microphone. Leave it empty and NearMic captures whichever source was the default when it started. It never captures itself. Set `NEARMIC_NO_DEFAULT=1` if NearMic should not become the default source.

The added delay is one 256-sample hop, about 5.3 ms, and it stays the same in suppress, bypass, and mute.

## What the chain does

The leveler is what makes a quiet voice loud. Gain moves only while the frame is above the speech threshold, freezes when it is not, and is capped at +30 dB. A fast gate ducks pauses so the frozen gain does not turn the room into a roar. The spectral denoiser runs before the leveler, so noise is not what gets amplified.

## Bake-off

```sh
sudo apt-get install pkg-config libpipewire-0.3-dev libspeexdsp-dev
zig build test
zig build bakeoff -Doptimize=ReleaseFast
```

`zig build bakeoff` rewrites `bench/RESULTS.md`. The release binary does not link SpeexDSP. `ldd` on `nearmic` should show only the system C library. PipeWire is loaded with `dlopen` when the live mic starts.

GitHub Actions builds that binary on every push and pull request. A tag `v*` uploads `nearmic-linux-x86_64` to the GitHub Release.

## Limits

This will not turn a Comica VM40 at two meters into a microphone on the chin. It will make the voice louder, steadier, and less hissy, and it takes some of the room bloom out. Hearing it in a call has to happen on the PipeWire machine that has the microphone.
