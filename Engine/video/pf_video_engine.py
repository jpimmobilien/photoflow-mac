#!/usr/bin/env python3
"""PhotoFlow local video engine (MLX, Apple Silicon).

Started by the app as a separate process for each job, so all GPU / unified memory is returned to macOS when the
job ends or is cancelled. Talks to the app through JSON lines on stdout that start with "PFEVENT ".

  pf_video_engine.py selftest                 MLX / Metal check (+ small numerical comparison GPU vs CPU)
  pf_video_engine.py generate --job job.json  text-to-video / image-to-video

job.json: {"model_dir", "prompt", "negative_prompt"?, "image"?, "width", "height", "num_frames", "steps"?,
           "guide_scale"?, "shift"?, "seed", "scheduler"?, "out_dir", "device"? ("gpu"|"cpu")}

Result in out_dir: frames.rgb (uint8, T×H×W×3), meta.json, preview_first/middle/last.png. The app encodes the
movie itself with AVFoundation (no ffmpeg involved).
"""
import json
import os
import sys
import time
import types
from pathlib import Path

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
sys.path.insert(0, str(Path(__file__).resolve().parent))

_t0 = time.time()


def emit(event, **kw):
    kw["event"] = event
    kw["t"] = round(time.time() - _t0, 2)
    sys.stdout.write("PFEVENT " + json.dumps(kw) + "\n")
    sys.stdout.flush()


def log(*a, **k):
    k.pop("file", None)
    print(*a, file=sys.stderr, **k)


def peak_gb():
    import mlx.core as mx
    try:
        return mx.get_peak_memory() / 1e9
    except AttributeError:
        return mx.metal.get_peak_memory() / 1e9


# ---------------------------------------------------------------------------------------------------------------
# Self test
# ---------------------------------------------------------------------------------------------------------------

def selftest():
    import platform
    import mlx.core as mx
    import numpy as np

    info = {"python": platform.python_version(), "mlx": getattr(mx, "__version__", "?"),
            "machine": platform.machine(), "macos": platform.mac_ver()[0]}
    try:
        info["metal"] = bool(mx.metal.is_available())
    except Exception as e:  # noqa: BLE001
        info["metal"] = False
        info["metal_error"] = str(e)
    if info["metal"]:
        try:
            di = mx.metal.device_info() if hasattr(mx.metal, "device_info") else mx.device_info()
            info["device"] = {k: (v if isinstance(v, (int, float, str)) else str(v)) for k, v in di.items()}
        except Exception as e:  # noqa: BLE001
            info["device_error"] = str(e)

    rng = np.random.default_rng(0)
    a = rng.standard_normal((512, 512)).astype(np.float32)
    b = rng.standard_normal((512, 512)).astype(np.float32)
    ref = a @ b
    results = {}
    for name, dev in (("cpu", mx.cpu), ("gpu", mx.gpu)):
        if name == "gpu" and not info["metal"]:
            continue
        try:
            with mx.stream(dev):
                t = time.time()
                c = mx.matmul(mx.array(a), mx.array(b))
                x = mx.random.normal((1, 5, 32, 32, 16), key=mx.random.key(1))
                w = mx.random.normal((16, 3, 3, 3, 16), key=mx.random.key(2)) * 0.1
                y = mx.conv3d(x, w, padding=1)
                mx.eval(c, y)
                err = float(np.abs(np.array(c) - ref).max())
                results[name] = {"matmul_max_err": err, "conv3d_mean": float(np.array(y).mean()),
                                 "conv3d_std": float(np.array(y).std()), "seconds": round(time.time() - t, 3)}
        except Exception as e:  # noqa: BLE001
            results[name] = {"error": str(e)}
    info["checks"] = results
    ok_cpu = results.get("cpu", {}).get("matmul_max_err", 1) < 1e-2
    ok_gpu = results.get("gpu", {}).get("matmul_max_err", 1) < 1e-2
    if ok_cpu and ok_gpu:
        d = abs(results["cpu"]["conv3d_std"] - results["gpu"]["conv3d_std"])
        info["gpu_matches_cpu"] = d < 1e-3
    info["ok"] = ok_cpu and (ok_gpu or not info["metal"])
    emit("selftest", **info)
    return 0 if info["ok"] else 1


# ---------------------------------------------------------------------------------------------------------------
# Offline tokenizer (replaces transformers.AutoTokenizer for google/umt5-xxl)
# ---------------------------------------------------------------------------------------------------------------

class _LocalUMT5Tokenizer:
    def __init__(self, directory: Path):
        from tokenizers import Tokenizer

        self.tok = Tokenizer.from_file(str(directory / "tokenizer.json"))

    def __call__(self, text, max_length=512, padding="max_length", truncation=True, return_tensors="np"):
        import numpy as np

        self.tok.no_padding()
        self.tok.no_truncation()
        if truncation:
            self.tok.enable_truncation(max_length=max_length)
        if padding == "max_length":
            self.tok.enable_padding(length=max_length, pad_id=0, pad_token="<pad>")
        enc = self.tok.encode(text)
        return {"input_ids": np.array([enc.ids], dtype=np.int32),
                "attention_mask": np.array([enc.attention_mask], dtype=np.int32)}


def install_shims(model_dir: Path, total_steps_hint=None):
    """Makes the vendored pipeline offline-only and reports progress as events."""
    tok_dir = model_dir / "tokenizer"

    tf = types.ModuleType("transformers")

    class AutoTokenizer:  # noqa: D401
        @staticmethod
        def from_pretrained(name, *a, **k):
            return _LocalUMT5Tokenizer(tok_dir)

    tf.AutoTokenizer = AutoTokenizer
    sys.modules["transformers"] = tf

    tq = types.ModuleType("tqdm")

    def tqdm(iterable, desc=None, **k):
        items = list(iterable)
        n = len(items)
        start = time.time()
        for i, x in enumerate(items):
            yield x
            elapsed = time.time() - start
            emit("progress", phase="denoise", step=i + 1, total=n, seconds_per_step=round(elapsed / (i + 1), 3),
                 peak_gb=round(peak_gb(), 2))

    tq.tqdm = tqdm
    sys.modules["tqdm"] = tq


def load_quantized_t5(model_dir: Path, config, qcfg):
    import mlx.core as mx
    import mlx.nn as nn
    from pfvideo.wan.text_encoder import T5Encoder

    enc = T5Encoder(vocab_size=config.t5_vocab_size, dim=config.t5_dim, dim_attn=config.t5_dim_attn,
                    dim_ffn=config.t5_dim_ffn, num_heads=config.t5_num_heads, num_layers=config.t5_num_layers,
                    num_buckets=config.t5_num_buckets, shared_pos=False)
    weights = {}
    for shard in sorted(model_dir.glob("t5_encoder-*.safetensors")):
        weights.update(mx.load(str(shard)))
    if qcfg:
        quantized_paths = {k[: -len(".scales")] for k in weights if k.endswith(".scales")}
        nn.quantize(enc, group_size=qcfg["group_size"], bits=qcfg["bits"],
                    class_predicate=lambda path, m: path in quantized_paths)
    enc.load_weights(list(weights.items()), strict=True)
    mx.eval(enc.parameters())
    return enc


# ---------------------------------------------------------------------------------------------------------------
# Generation
# ---------------------------------------------------------------------------------------------------------------

def generate(job_path: str):
    job = json.loads(Path(job_path).read_text())
    model_dir = Path(job["model_dir"])
    out_dir = Path(job["out_dir"])
    out_dir.mkdir(parents=True, exist_ok=True)
    cfg = json.loads((model_dir / "config.json").read_text())
    t5_q = cfg.get("pf_t5_quantization")

    install_shims(model_dir)
    import mlx.core as mx
    import numpy as np

    if job.get("device") == "cpu":
        mx.set_default_device(mx.cpu)
    emit("start", device=str(mx.default_device()), mlx=getattr(mx, "__version__", "?"))

    import pfvideo.wan.generate as G

    G.print = log  # the vendored pipeline prints colourful progress; keep stdout for events

    orig_load_wan_model = G.load_wan_model
    orig_load_vae_decoder = G.load_vae_decoder

    def _t5(path, config):
        emit("phase", phase="text_encoder")
        if (model_dir / "t5_encoder.safetensors").exists():
            from pfvideo.wan.utils import load_t5_encoder
            return load_t5_encoder(path, config)
        return load_quantized_t5(model_dir, config, t5_q)

    def _wan(*a, **k):
        emit("phase", phase="load_transformer", peak_gb=round(peak_gb(), 2))
        return orig_load_wan_model(*a, **k)

    def _vae(*a, **k):
        emit("phase", phase="decode", peak_gb=round(peak_gb(), 2))
        return orig_load_vae_decoder(*a, **k)

    result = {}

    def _save(frames, output_path, fps=16):
        frames = np.ascontiguousarray(frames, dtype=np.uint8)
        t, h, w, _ = frames.shape
        frames.tofile(out_dir / "frames.rgb")
        from PIL import Image
        for name, idx in (("first", 0), ("middle", t // 2), ("last", t - 1)):
            Image.fromarray(frames[idx]).save(out_dir / f"preview_{name}.png")
        f = frames.astype(np.float32) / 255.0
        luma = f[..., 0] * 0.299 + f[..., 1] * 0.587 + f[..., 2] * 0.114
        per_frame_std = luma.reshape(t, -1).std(axis=1)
        diffs = np.abs(np.diff(luma, axis=0)).reshape(t - 1, -1).mean(axis=1) if t > 1 else np.zeros(1)
        result.update(frames=int(t), width=int(w), height=int(h), fps=int(fps),
                      luma_mean=float(luma.mean()), luma_std_min=float(per_frame_std.min()),
                      luma_std_mean=float(per_frame_std.mean()),
                      temporal_diff_mean=float(diffs.mean()), temporal_diff_max=float(diffs.max()))

    G.load_t5_encoder = _t5
    G.load_wan_model = _wan
    G.load_vae_decoder = _vae
    G.save_video = _save

    seed = int(job.get("seed", 42))
    G.generate_video(
        model_dir=str(model_dir), prompt=job["prompt"], negative_prompt=job.get("negative_prompt"),
        image=job.get("image"), width=int(job["width"]), height=int(job["height"]),
        num_frames=int(job["num_frames"]), steps=job.get("steps"), guide_scale=job.get("guide_scale"),
        shift=job.get("shift"), seed=seed, output_path=str(out_dir / "unused.mp4"),
        scheduler=job.get("scheduler", "unipc"), tiling=job.get("tiling", "auto"),
        no_compile=bool(job.get("no_compile", False)), trim_first_frames=int(job.get("trim_first_frames", 0)),
    )
    result.update(seed=seed, seconds=round(time.time() - _t0, 1), peak_gb=round(peak_gb(), 2))
    (out_dir / "meta.json").write_text(json.dumps(result, indent=2))
    emit("done", **result)
    return 0


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    cmd = sys.argv[1]
    try:
        if cmd == "selftest":
            return selftest()
        if cmd == "generate":
            return generate(sys.argv[sys.argv.index("--job") + 1])
    except Exception as e:  # noqa: BLE001
        import traceback
        traceback.print_exc()
        emit("error", message=f"{type(e).__name__}: {e}")
        return 1
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
