"""Probe which Apple-Silicon compute backends actually work on this Mac (MLX/Metal, PyTorch MPS).
Prints one JSON line. Used by CI and by the in-app hardware test."""
import json, platform, sys, time

out = {"python": sys.version.split()[0], "machine": platform.machine(), "mac": platform.mac_ver()[0]}

try:
    import mlx.core as mx
    import numpy as np
    out["mlx"] = mx.__version__
    out["mlx_metal_available"] = bool(mx.metal.is_available())
    try:
        out["mlx_device_info"] = {k: (v if isinstance(v, (int, float, str)) else str(v)) for k, v in mx.metal.device_info().items()}
    except Exception as e:  # noqa
        out["mlx_device_info"] = str(e)
    rng = np.random.default_rng(0)
    a = rng.standard_normal((1024, 1024)).astype(np.float32)
    b = rng.standard_normal((1024, 1024)).astype(np.float32)
    ref = a @ b
    for dev_name, dev in (("gpu", mx.gpu), ("cpu", mx.cpu)):
        try:
            t = time.time()
            with mx.stream(dev):
                c = mx.matmul(mx.array(a), mx.array(b))
                mx.eval(c)
            err = float(np.abs(np.array(c) - ref).max() / np.abs(ref).max())
            # bf16 attention-like op
            with mx.stream(dev):
                q = mx.random.normal((1, 8, 256, 64)).astype(mx.bfloat16)
                o = mx.fast.scaled_dot_product_attention(q, q, q, scale=0.125)
                mx.eval(o)
            out[f"mlx_{dev_name}"] = {"ok": err < 1e-3, "rel_err": err, "seconds": round(time.time() - t, 3),
                                     "sdpa_bf16_finite": bool(mx.all(mx.isfinite(o.astype(mx.float32))).item())}
        except Exception as e:
            out[f"mlx_{dev_name}"] = {"ok": False, "error": str(e)[:300]}
except Exception as e:
    out["mlx"] = f"unavailable: {e}"[:300]

try:
    import torch
    out["torch"] = torch.__version__
    out["mps_available"] = bool(torch.backends.mps.is_available())
    if out["mps_available"]:
        x = torch.randn(512, 512)
        y = (x.to("mps") @ x.to("mps")).cpu()
        out["mps_matmul_rel_err"] = float(((y - x @ x).abs().max() / (x @ x).abs().max()).item())
except Exception as e:
    out["torch"] = f"unavailable: {e}"[:200]

print(json.dumps(out))
