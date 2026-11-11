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
  -> voice.Post: 90 Hz HPF, -2 dB low shelf @300 Hz,
                 +4 dB peaking @3.2 kHz (Q 1.0), +2 dB shelf @8 kHz,
                 speech leveler (4:1 above -24 dBFS, up to +12 dB lift
                 below it, scaled by presence over the tracked noise floor,
                 60 ms RMS, 10/300 ms, ramped per sample),
                 +6 dB trim,
                 look-ahead limiter -2.0 dBFS (256 samples of look-ahead)
  -> NearMic source `nearmic` (capture_MONO)
  -> UAC2 gadget playback_MONO
  -> host microphone
```

The leveler is the far-field fix, and the limiter is what makes it loud
without popping. A plain makeup gain would lift the noise floor by the same
amount; this one measures the level against a 15 s-rise noise floor and only
lifts while speech is present, so pauses stay at -60 dBFS. The look-ahead
limiter knows the next block's peak before that block reaches the output, so
it is already at the right gain when a loud syllable arrives: no overshoot,
no flat-topped clipping, no "pop". That is what allows the +12 dB lift and
the +6 dB trim instead of hiding 10 dB of headroom.

The +4 dB presence peak at 3.2 kHz and the -2 dB shelf at 300 Hz are the
"closeness" EQ: distance softens consonants and adds boxy low-mid, so the
chain does the opposite. The 8 kHz shelf restores air without the 3 dB
broadband sibilance a full high shelf produces.

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

## Measured alternatives (hushmic/DPDFNet, LocalVQE)

Both were built and run on the operator's own Maono recording before choosing
to keep RNNoise.

**hushmic / DPDFNet** (ONNX Runtime 1.27, `dpdfnet8_48khz_hr` and
`dpdfnet2_48khz_hr`, x86-64 workstation with AVX2, single-threaded):

| Model | 6.0 s of audio | realtime factor | Latency |
| --- | ---: | ---: | ---: |
| dpdfnet8 (quality) | 2.39 s | 2.5x | 80 ms |
| dpdfnet2 (light) | 0.86 s | 7.0x | 80 ms |

DPDFNet removes essentially all of the room tone on that clip (mean -91 dBFS
against -44 dBFS in), but it costs 50 ms more look-ahead than the current
chain. The RK3399 has no AVX2/FMA, so ONNX Runtime falls back to NEON: expect
roughly 4-6x the desktop cost per core, which puts dpdfnet8 below realtime and
dpdfnet2 at 1-2x. Porting also means shipping ONNX Runtime aarch64 plus the
STFT/mask streaming layer.

**LocalVQE** is 16 kHz only (8 kHz of bandwidth) and every joint model needs a
far-end reference for AEC. v1.2 (1.3 M) runs 3.7x realtime on a Zen4 core,
which maps to well under 1x on a Cortex-A72; the compact GTCRN line (~49 K) is
fast enough (~8x on an A72) but is still 16 kHz. On a full-band 48 kHz
microphone it would sound duller than RNNoise regardless of noise suppression.

Conclusion: 48 kHz RNNoise plus the post chain above is the best quality that
runs in realtime on this board. The "sounds far away" complaint was a level and
EQ problem, not a model problem.

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

## 2026-11-11: DeepFilterNet3 live, and why it sounded robotic

Scored with DNSMOS P.835 (`scripts/score-dnsmos.py`) on 45 s of the operator's
own far-field speech recorded from the Maono (speech about -30 dBFS, room
-55 dBFS):

| Chain | SIG | BAK | OVRL | speech dBFS |
| --- | ---: | ---: | ---: | ---: |
| raw | 2.32 | 2.37 | 1.84 | -28.6 |
| RNNoise + post | 3.05 | 3.80 | 2.71 | -17.2 |
| DeepFilterNet3 + post (offline) | 3.38 | 4.10 | 3.12 | -17.1 |
| DeepFilterNet3 + post, live path before the fix | 3.09 | 3.91 | 2.77 | -20.2 |
| DeepFilterNet3 + post, live path after the fix | 3.37 | 4.10 | 3.11 | -17.5 |

- The live path was worse than the same DSP offline because no audio thread
  had realtime priority (see AGENTS.md, 24/7 policy). The live capture had 478
  holes of 128-255 samples in 47 s; after `rt_group_sched=0` and the
  `performance` governor the live result equals the offline one.
- DeepFilterNet3 beats RNNoise by 0.4 OVRL on this voice. Attenuation limits
  (12-30 dB), the post-filter and libDF's stage-skipping thresholds
  (`DF_MIN_DB`, `DF_MAX_ERB_DB`, `DF_MAX_DF_DB`) changed the score by less
  than 0.05; they stay available as environment switches.
- Post chain defaults changed: gate depth -45 -> -20 dB (no dead air between
  words, same score), leveler trim +6 -> +9 dB (speech -19.7 -> -17.1 dBFS).
  `NEARMIC_GATE_DB`, `NEARMIC_TRIM_DB`, `NEARMIC_LIFT_DB` override them.
- What still limits "sounds close": the room reverberation in the far-field
  input. SIG stays near 3.4 for every setting tried.

