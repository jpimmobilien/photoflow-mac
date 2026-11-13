#!/usr/bin/env python3
"""Lists candidate model repositories on Hugging Face (official orgs only) with licence, folders and sizes.
Output: probe/summary.json + probe/summary.txt (read by the PhotoFlow catalog generator)."""
import json, os, sys, urllib.request, collections

REPOS = [
    "apple/coreml-stable-diffusion-2-1-base",
    "apple/coreml-stable-diffusion-2-1-base-palettized",
    "apple/coreml-stable-diffusion-v1-5",
    "apple/coreml-stable-diffusion-v1-5-palettized",
    "apple/coreml-stable-diffusion-xl-base",
    "apple/coreml-stable-diffusion-xl-base-ios",
    "apple/coreml-stable-diffusion-mixed-bit-palettization",
    "black-forest-labs/FLUX.1-schnell",
    "stabilityai/sdxl-turbo",
    "stabilityai/stable-diffusion-xl-base-1.0",
    "stabilityai/stable-diffusion-2-1-base",
    "stabilityai/stable-diffusion-2-inpainting",
    "stable-diffusion-v1-5/stable-diffusion-inpainting",
    "Sanster/lama",
    "smartywu/big-lama",
    "Carve/LaMa-ONNX",
]

def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "PhotoFlow-model-probe"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)

out, lines = {}, []
for repo in REPOS:
    try:
        info = get(f"https://huggingface.co/api/models/{repo}?blobs=true")
    except Exception as e:
        lines.append(f"## {repo}: ERROR {e}"); out[repo] = {"error": str(e)}; continue
    card = info.get("cardData") or {}
    sib = info.get("siblings", [])
    groups = collections.OrderedDict()
    zips = []
    for s in sib:
        f = s["rfilename"]; size = s.get("size") or 0
        if f.endswith(".zip"): zips.append((f, size, (s.get("lfs") or {}).get("sha256")))
        parts = f.split("/")
        key = None
        for i, p in enumerate(parts):
            if p.endswith(".mlmodelc") or p.endswith(".mlpackage"):
                key = "/".join(parts[: i + 1]); break
        if key is None: key = "/".join(parts[:-1]) + "/" + parts[-1] if len(parts) < 3 else "/".join(parts[:2]) + "/*"
        g = groups.setdefault(key, [0, 0]); g[0] += size; g[1] += 1
    out[repo] = {"license": card.get("license"), "license_name": card.get("license_name"), "gated": info.get("gated"),
                 "sha": info.get("sha"), "groups": groups, "zips": zips, "tags": info.get("tags", [])[:30]}
    lines.append(f"## {repo}  licence={card.get('license')} {card.get('license_name') or ''} gated={info.get('gated')} sha={info.get('sha')}")
    for k, (sz, n) in groups.items():
        lines.append(f"   {sz/1e6:10.1f} MB  {n:4d} files  {k}")
    for z in zips: lines.append(f"   ZIP {z[1]/1e6:10.1f} MB  {z[0]}  sha256={z[2]}")

os.makedirs("probe", exist_ok=True)
json.dump(out, open("probe/summary.json", "w"), indent=1)
open("probe/summary.txt", "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
