#!/usr/bin/env python3
"""Writes lama-manifest.json (size + SHA-256 of the converted package and of the source weights)."""
import glob, hashlib, json, os
def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""): h.update(b)
    return h.hexdigest()
w = glob.glob(os.path.expanduser("~/.cache/torch/hub/checkpoints/big-lama.pt"))
m = {"lama": {"file": "lama.mlpackage.zip", "size": os.path.getsize("lama.mlpackage.zip"), "sha256": sha("lama.mlpackage.zip"),
              "input": 800, "source": "https://github.com/Sanster/models/releases/download/add_big_lama/big-lama.pt",
              "weights_sha256": sha(w[0]) if w else None, "license": "Apache-2.0"}}
json.dump(m, open("lama-manifest.json", "w"), indent=1)
print(m)
