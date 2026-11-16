#!/usr/bin/env python3
"""Builds a PhotoFlow video model pack (MLX) from an official Wan checkpoint.

Runs in CI (needs torch for the .pth files), never on the user's Mac. The pack contains
  config.json                       model configuration (pfvideo.wan.config)
  model[-0000N].safetensors         transformer, bfloat16 (or int8 with --dit-bits 8), sharded < 1.9 GB
  t5_encoder-0000N.safetensors      UMT5-XXL encoder, int8 (affine, group 64), sharded
  vae.safetensors                   3D VAE, float32
  tokenizer/tokenizer.json          UMT5 tokenizer (offline)
  pf_pack.json                      file list with size + SHA-256, quantisation, source revision

Usage: pf_convert.py --src <wan snapshot> --tokenizer <umt5 tokenizer dir> --out <dir> [--t5-bits 8] [--dit-bits 0]
"""
import argparse
import gc
import hashlib
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import mlx.core as mx  # noqa: E402

SHARD_BYTES = 1_900_000_000
T5_QUANT_SUFFIXES = (".attn.q.weight", ".attn.k.weight", ".attn.v.weight", ".attn.o.weight",
                     ".ffn.fc1.weight", ".ffn.fc2.weight", ".ffn.gate_proj.weight")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 22), b""):
            h.update(b)
    return h.hexdigest()


class ShardWriter:
    def __init__(self, out_dir: Path, stem: str):
        self.out_dir, self.stem = out_dir, stem
        self.buf, self.size, self.index, self.files = {}, 0, 0, []

    def add(self, key, arr):
        mx.eval(arr)
        n = arr.nbytes
        if self.buf and self.size + n > SHARD_BYTES:
            self.flush()
        self.buf[key] = arr
        self.size += n

    def flush(self):
        if not self.buf:
            return
        self.index += 1
        name = f"{self.stem}-{self.index:05d}.safetensors"
        mx.save_safetensors(str(self.out_dir / name), self.buf)
        self.files.append(name)
        print(f"  wrote {name} ({self.size / 1e9:.2f} GB, {len(self.buf)} tensors)", flush=True)
        self.buf, self.size = {}, 0
        gc.collect()


def convert_t5(pth: Path, out_dir: Path, bits: int, group: int = 64):
    """Streams the UMT5-XXL .pth tensor by tensor (mmap) so peak memory stays near one shard."""
    import torch

    print(f"Converting T5 encoder ({'int%d' % bits if bits else 'bfloat16'}) …", flush=True)
    sd = torch.load(str(pth), map_location="cpu", weights_only=True, mmap=True)
    w = ShardWriter(out_dir, "t5_encoder")
    quantized = 0
    for key in list(sd.keys()):
        t = sd[key]
        if not isinstance(t, torch.Tensor):
            continue
        new_key = key.replace(".ffn.gate.0.", ".ffn.gate_proj.")
        arr = mx.array(t.detach().to(torch.float32).numpy())
        is_linear = new_key.endswith(T5_QUANT_SUFFIXES)
        is_embedding = new_key == "token_embedding.weight"
        if bits and (is_linear or is_embedding) and arr.ndim == 2 and arr.shape[-1] % group == 0:
            # float32 source → float32 scales/biases, so the quantised encoder computes in float32 like the original
            wq, scales, biases = mx.quantize(arr, group_size=group, bits=bits)
            base = new_key[: -len("weight")]
            w.add(base + "weight", wq)
            w.add(base + "scales", scales)
            w.add(base + "biases", biases)
            quantized += 1
        else:
            w.add(new_key, arr.astype(mx.float32))
        del arr, t
    w.flush()
    del sd
    gc.collect()
    print(f"  {quantized} matrices quantised", flush=True)
    return w.files


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--tokenizer", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--t5-bits", type=int, default=8, choices=[0, 4, 8])
    ap.add_argument("--dit-bits", type=int, default=0, choices=[0, 4, 8])
    ap.add_argument("--source-name", default="")
    ap.add_argument("--source-revision", default="")
    args = ap.parse_args()

    src, out = Path(args.src), Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    # 1. Transformer + VAE + config with the vendored converter (T5 is left out and streamed below).
    from pfvideo.wan.convert import convert_wan_checkpoint

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        for item in src.iterdir():
            if item.name.startswith("models_t5_"):
                continue
            (tmp / item.name).symlink_to(item.resolve())
        convert_wan_checkpoint(str(tmp), str(out), dtype="bfloat16",
                               quantize=args.dit_bits > 0, bits=args.dit_bits or 4)
    gc.collect()

    # Split large transformer files (release assets ≤ 2 GB).
    for stem in ("model", "low_noise_model", "high_noise_model"):
        f = out / f"{stem}.safetensors"
        if f.exists() and f.stat().st_size > SHARD_BYTES:
            weights = mx.load(str(f))
            w = ShardWriter(out, stem)
            for k in sorted(weights):
                w.add(k, weights[k])
            w.flush()
            del weights
            f.unlink()

    # 2. T5 encoder, streamed and quantised.
    t5 = next(src.glob("models_t5_*.pth"))
    convert_t5(t5, out, args.t5_bits)

    # 3. Tokenizer (offline).
    tok_out = out / "tokenizer"
    tok_out.mkdir(exist_ok=True)
    for name in ("tokenizer.json", "tokenizer_config.json", "special_tokens_map.json", "spiece.model"):
        p = Path(args.tokenizer) / name
        if p.exists():
            shutil.copy(p, tok_out / name)
    assert (tok_out / "tokenizer.json").exists(), "tokenizer.json missing"

    # 4. Config: record quantisation of the text encoder for the engine.
    cfg_path = out / "config.json"
    cfg = json.loads(cfg_path.read_text())
    cfg["pf_t5_quantization"] = {"bits": args.t5_bits, "group_size": 64} if args.t5_bits else None
    cfg_path.write_text(json.dumps(cfg, indent=2))

    files = []
    for p in sorted(out.rglob("*")):
        if p.is_file() and p.name != "pf_pack.json":
            files.append({"path": str(p.relative_to(out)), "size": p.stat().st_size, "sha256": sha256(p)})
    pack = {"format": 1, "source": args.source_name, "source_revision": args.source_revision,
            "t5_bits": args.t5_bits, "dit_bits": args.dit_bits, "files": files}
    (out / "pf_pack.json").write_text(json.dumps(pack, indent=2))
    total = sum(f["size"] for f in files)
    print(f"Pack complete: {len(files)} files, {total / 1e9:.2f} GB", flush=True)


if __name__ == "__main__":
    main()
