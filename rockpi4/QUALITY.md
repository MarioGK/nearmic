# NearMic voice quality

This is the quality decision for the ROCK 4 Plus v1.73 appliance. The board
runs the NearMic Zig DSP between the USB microphone (Maono ProStudio 2x2 Lite,
input 1) and the UAC2 gadget that the host computer sees as a microphone.

## References studied

| Reference | Model / chain | Rate / hop | Latency | What it does right |
| --- | --- | --- | --- | --- |
| `Fovty/hushmic` | DPDFNet2/DPDFNet8 48 kHz | 48 kHz, 480-sample hop | 2400 samples (50 ms) | One learned mask; no spectral subtraction, AGC, EQ or separate dereverb; a latency-aligned floor blend caps suppression and avoids musical noise |
| `localai-org/LocalVQE` | DeepVQE derivative, joint AEC/NS/dereverb | 16 kHz, 256-sample hop | ~17 ms | Learned complex mask, causal streaming; AEC-oriented and needs a far-end reference; 16 kHz limits bandwidth to 8 kHz |
| RNNoise | recurrent neural denoiser | 48 kHz, 480-sample frame | ~10 ms | Full-band, small, fast on CPU; no model weights to ship separately |

## Why the old chain sounded robotic

The previous `dsp-dereverb` + `rock-pi-plus` ensemble had:

- A 42.7 ms delayed-magnitude "dereverb" subtraction with the current phase
  (an 8-hop comb; metallic/choroidal coloration).
- Oversubtraction and a hard −24 dB gain floor (musical noise).
- Three hypotheses averaged with different gain curves (warbling).
- Broad noise-floor gating that closed on breaths and harmonics.
- AGC with a −34 dB non-speech duck (pumping room tone and keyboard tails).
- A +3–4 dB presence shelf that made sibilance harsh.
- Peak pinned at −0.4 dBFS by the limiter.
- A 0.51 % capture/playout clock deficit that drained the output ring and
  produced periodic underruns/dropouts.

## Current chain

```
Maono input 1
  -> RNNoise (learned full-band denoiser, 48 kHz)
  -> voice.Post: 75 Hz HPF, low shelf -1 dB @250 Hz,
                 +3 dB presence @3 kHz, +1.5 dB air @7 kHz,
                 speech leveler (3:1 above -18 dBFS, up to +16 dB lift
                 below it, scaled by presence over the tracked noise
                 floor), soft limiter -1.5 dBFS
  -> NearMic source `nearmic` (capture_MONO)
  -> UAC2 gadget playback_MONO
  -> host microphone
```

The leveler is the far-field fix. A plain makeup gain would have to lift the
noise floor by the same 6-16 dB; this one measures the level against a
15 s-rise noise floor and only applies lift while the signal is above it, so
quiet speech arrives at the same loudness as close speech and pauses stay
quiet. Presence and air shelves restore the high end that distance and room
absorption remove, which is most of the "sounds far away" cue.

`src/app.zig` also runs a fractional ASRC with a proportional drift servo
(target reserve 2048 samples, ratio 0.985–1.015) to absorb the USB clock
difference between the Maono capture and the UAC2 gadget.

## Measured

| Signal | Peak | Speech RMS | HF >4 kHz | Centroid |
| --- | ---: | ---: | ---: | ---: |
| Raw Maono | −6.4 dBFS | −28.1 dBFS | 16.3 % | 2151 Hz |
| Old `dsp-dereverb` | −0.4 dBFS | −20.3 dBFS | 25.2 % | 2935 Hz |
| Single `dsp` | −2.2 dBFS | −19.5 dBFS | 23.4 % | 2730 Hz |
| **RNNoise + post** | **−4.8 dBFS** | **−24.5 dBFS** | **12.8 %** | **1805 Hz** |

Live board:

- `engine=rnnoise`, `gain_db=10`, `threads=1`, `cpu_budget=0.80`
- `out_fill=768–1024` (16-21 ms of ring); a startup burst of a few
  128-sample underruns, then ~1 per 10 s of a single period (inaudible)
- 128-frame graph (`clock.force-quantum=128`), 128-frame UAC2 ALSA periods
- ~36 % of one core = ~6 % of the 6-core RK3399; ~23 MB RSS
- `nearmic qa`: p99 0.90 ms per 5.33 ms block, about 6x faster than realtime
- board latency budget ~29-34 ms end to end, measured from the ring fill,
  graph quantum and the 480-sample RNNoise frame
- `qa`: `rock-pi-plus`, p99 ~1.38 ms per 5.33 ms hop

## Build

RNNoise is statically linked for aarch64 with
`scripts/build-rnnoise-aarch64.sh`, then:

```sh
zig build -Dtarget=aarch64-linux-gnu -Dcpu=cortex_a53 \
  -Doptimize=ReleaseFast -Dbundle=true
```

The binary is glibc (not musl): a static musl binary cannot `dlopen` Debian's
glibc PipeWire library.

## Limits

- **DPDFNet** would be the strongest quality option, but the native runtime is
  Linux x86_64 only and its kernels are AVX2/FMA; it returns 0 on ARM. Porting
  it or using ONNX Runtime aarch64 is a separate project.
- **LocalVQE** is 16 kHz (8 kHz audio bandwidth) and AEC-oriented; it needs a
  far-end reference and a GGML shared library. It is feasible under the CPU
  budget but would sound band-limited next to full-band RNNoise.
- RNNoise is the best full-band 48 kHz neural option that builds and runs on
  this board today. The 80 % CPU allowance is not fully used because a heavier
  full-band model is not available in a portable aarch64 build.
- The UAC2 gadget and Maono clocks are independent USB domains. The ASRC servo
  in NearMic absorbs the drift; do not remove it when changing the DSP.
