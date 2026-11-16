"""Content checks for generated videos (same thresholds as PhotoFlow's AIImageValidator for single
frames, plus temporal checks). Works on uint8 frames (F, H, W, 3)."""
import numpy as np


def _luma(f):
    f = f.astype(np.float32) / 255.0
    return 0.2126 * f[..., 0] + 0.7152 * f[..., 1] + 0.0722 * f[..., 2]


def frame_metrics(frame):
    y = _luma(frame)
    std = float(y.std())
    lap = np.abs(4 * y[1:-1, 1:-1] - y[:-2, 1:-1] - y[2:, 1:-1] - y[1:-1, :-2] - y[1:-1, 2:])
    noise = float(lap.mean() / max(std, 1e-4))
    extreme = float(((y < 0.02) | (y > 0.98)).mean())
    return {"std": std, "noise": noise, "extreme": extreme, "mean": float(y.mean())}


def check(frames):
    """Returns (ok, metrics, reasons)."""
    frames = np.asarray(frames)
    n = len(frames)
    reasons = []
    if n == 0:
        return False, {}, ["no frames"]
    idx = sorted(set([0, n // 4, n // 2, (3 * n) // 4, n - 1]))
    per = [frame_metrics(frames[i]) for i in idx]
    worst_std = min(p["std"] for p in per)
    worst_noise = max(p["noise"] for p in per)
    worst_extreme = max(p["extreme"] for p in per)
    lum = [_luma(f) for f in frames]
    diffs = [float(np.abs(lum[i + 1] - lum[i]).mean()) for i in range(n - 1)]
    mean_diff = float(np.mean(diffs)) if diffs else 0.0
    max_diff = float(np.max(diffs)) if diffs else 0.0
    # Flicker: frame-to-frame change of global brightness that reverses direction (A-B-A)
    means = np.array([l.mean() for l in lum])
    flicker = 0.0
    if n >= 3:
        d = np.diff(means)
        # magnitude of brightness reversals between neighbouring frames (0 for monotone changes)
        flicker = float(np.mean(np.maximum(0, -(d[1:] * d[:-1])) ** 0.5))
    metrics = {"frames": n, "worst_std": worst_std, "worst_noise": worst_noise, "worst_extreme": worst_extreme,
               "mean_frame_diff": mean_diff, "max_frame_diff": max_diff, "brightness_flicker": flicker,
               "sampled": per}
    if worst_std < 0.03:
        reasons.append("frame is almost uniform (empty image)")
    if worst_noise > 0.9:
        reasons.append("frame looks like noise")
    if worst_extreme > 0.9:
        reasons.append("frame is almost completely black or white")
    if n > 1 and max_diff > 0.35:
        reasons.append("abrupt change between consecutive frames")
    if n > 4 and mean_diff < 0.0005:
        reasons.append("no motion (all frames identical)")
    return len(reasons) == 0, metrics, reasons
