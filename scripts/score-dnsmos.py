# /// script
# requires-python = ">=3.10"
# dependencies = ["onnxruntime", "numpy", "soundfile", "scipy"]
# ///
"""Score WAV files with DNSMOS P.835 (SIG/BAK/OVRL) plus level statistics.

    uv run scripts/score-dnsmos.py <dnsmos-model-dir> a.wav b.wav ...

<dnsmos-model-dir> holds sig_bak_ovr.onnx from
https://github.com/microsoft/DNS-Challenge/tree/master/DNSMOS/DNSMOS

SIG: speech quality (robotic/warbling/muffled lowers it), BAK: background
noise (5 = none), OVRL: overall. Clips are resampled to 16 kHz as DNSMOS
expects; clips shorter than 9.01 s are looped, as the reference script does.

Level columns: `speech` is the RMS of the loudest 30 % of 20 ms frames
(dBFS), `floor` the RMS of the quietest 10 % (the noise left in pauses),
`peak` the sample peak.
"""
import sys
from pathlib import Path

import numpy as np
import onnxruntime as ort
import soundfile as sf
from scipy.signal import resample_poly

FS = 16000
LEN = 9.01
P_OVR = np.poly1d([-0.06766283, 1.11546468, 0.04602535])
P_SIG = np.poly1d([-0.08397278, 1.22083953, 0.0052439])
P_BAK = np.poly1d([-0.13166888, 1.60915514, -0.39604546])


def db(x: float) -> float:
    return 20 * np.log10(max(x, 1e-9))


def levels(x: np.ndarray, fs: int) -> tuple[float, float, float]:
    n = int(0.02 * fs)
    frames = x[: len(x) // n * n].reshape(-1, n)
    rms = np.sqrt(np.mean(frames**2, axis=1))
    rms.sort()
    k = max(1, len(rms) // 10)
    floor = float(np.sqrt(np.mean(rms[:k] ** 2)))
    loud = rms[int(len(rms) * 0.7) :]
    speech = float(np.sqrt(np.mean(loud**2)))
    return db(speech), db(floor), db(float(np.max(np.abs(x))))


def score(sess: ort.InferenceSession, path: str) -> dict:
    x, fs = sf.read(path, dtype="float32", always_2d=True)
    x = x[:, 0]
    speech, floor, peak = levels(x, fs)
    a = resample_poly(x, FS, fs).astype(np.float32) if fs != FS else x
    need = int(LEN * FS)
    while len(a) < need:
        a = np.concatenate([a, a])
    hops = int(np.floor(len(a) / FS) - LEN) + 1
    s, b, o = [], [], []
    for i in range(hops):
        seg = a[i * FS : i * FS + need]
        if len(seg) < need:
            continue
        sig, bak, ovr = sess.run(None, {"input_1": seg[np.newaxis, :]})[0][0]
        s.append(P_SIG(sig))
        b.append(P_BAK(bak))
        o.append(P_OVR(ovr))
    return {
        "file": Path(path).name,
        "SIG": float(np.mean(s)),
        "BAK": float(np.mean(b)),
        "OVRL": float(np.mean(o)),
        "speech": speech,
        "floor": floor,
        "peak": peak,
    }


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    sess = ort.InferenceSession(str(Path(sys.argv[1]) / "sig_bak_ovr.onnx"))
    print("| file | SIG | BAK | OVRL | speech dBFS | floor dBFS | peak dBFS |")
    print("| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
    for p in sys.argv[2:]:
        r = score(sess, p)
        print(
            f"| {r['file']} | {r['SIG']:.2f} | {r['BAK']:.2f} | {r['OVRL']:.2f} "
            f"| {r['speech']:.1f} | {r['floor']:.1f} | {r['peak']:.1f} |"
        )


if __name__ == "__main__":
    main()
