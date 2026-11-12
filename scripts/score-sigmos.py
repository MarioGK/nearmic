# /// script
# requires-python = ">=3.10,<3.13"
# dependencies = ["onnxruntime", "numpy", "soundfile", "scipy", "librosa"]
# ///
"""Score WAV files with SIGMOS (Microsoft SIG-Challenge, ICASSP 2024), full band 48 kHz.

    uv run scripts/score-sigmos.py <sigmos-dir> a.wav b.wav ...

<sigmos-dir> holds sigmos.py and model-sigmos_1697718653_41d092e8-epo-200.onnx from
https://github.com/microsoft/SIG-Challenge/tree/main/ICASSP2024/sigmos

Columns are 1-5 MOS predictions (higher is better): COL coloration, DISC
discontinuity, LOUD loudness, NOISE, REVERB, SIG speech signal, OVRL overall.
Each file is scored in 10 s windows over its speech-active part and averaged.
"""
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

sys.path.insert(0, sys.argv[1])
from sigmos import SigMOS  # noqa: E402

est = SigMOS(model_dir=sys.argv[1])
keys = ["MOS_COL", "MOS_DISC", "MOS_LOUD", "MOS_NOISE", "MOS_REVERB", "MOS_SIG", "MOS_OVRL"]
print("| file | " + " | ".join(k[4:] for k in keys) + " |")
print("| --- |" + " ---: |" * len(keys))
for p in sys.argv[2:]:
    x, fs = sf.read(p)
    if x.ndim > 1:
        x = x[:, 0]
    win = 10 * fs
    rows = []
    for s in range(0, max(1, len(x) - win + 1), win):
        seg = x[s : s + win]
        if np.sqrt((seg**2).mean()) < 1e-4:
            continue
        r = est.run(seg.astype(np.float32), sr=fs)
        rows.append([r[k] for k in keys])
    m = np.mean(rows, axis=0)
    print(f"| {Path(p).name} | " + " | ".join(f"{v:.2f}" for v in m) + " |")
