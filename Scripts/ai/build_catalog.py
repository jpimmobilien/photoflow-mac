#!/usr/bin/env python3
"""Builds the file list (pinned revision, size, SHA-256) for every downloadable model in PhotoFlow's catalog.
LFS files carry their SHA-256 in the Hugging Face API; small non-LFS files are downloaded and hashed here.
Output: catalog/files.json  {model_id: {"revision":…, "files":[{"path","url","size","sha256"}]}}"""
import hashlib, json, os, urllib.request

HF = {
    "sdxl-mbp": ("apple/coreml-stable-diffusion-mixed-bit-palettization", "coreml-stable-diffusion-xl-base_mbp_4_50_palettized/compiled/", []),
    "sdxl-fp16": ("apple/coreml-stable-diffusion-xl-base", "compiled/", []),
    "sd21-palettized": ("apple/coreml-stable-diffusion-2-1-base-palettized", "original/compiled/", []),
    "sd21-fp16": ("apple/coreml-stable-diffusion-2-1-base", "original/compiled/", ["UnetChunk1.mlmodelc", "UnetChunk2.mlmodelc"]),
}
AGENT = {"User-Agent": "model-catalog-builder"}


def get_json(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=AGENT), timeout=60) as r:
        return json.load(r)


def sha_of_url(url):
    h = hashlib.sha256(); n = 0
    with urllib.request.urlopen(urllib.request.Request(url, headers=AGENT), timeout=120) as r:
        while True:
            b = r.read(1 << 20)
            if not b: break
            h.update(b); n += len(b)
    return h.hexdigest(), n


out = {}
for mid, (repo, prefix, exclude) in HF.items():
    info = get_json(f"https://huggingface.co/api/models/{repo}?blobs=true")
    rev = info["sha"]
    files = []
    for s in info["siblings"]:
        f = s["rfilename"]
        if not f.startswith(prefix): continue
        rel = f[len(prefix):]
        if any(rel.startswith(e + "/") or rel == e for e in exclude): continue
        url = f"https://huggingface.co/{repo}/resolve/{rev}/{f}"
        lfs = s.get("lfs") or {}
        if lfs.get("sha256"):
            sha, size = lfs["sha256"], s.get("size") or lfs.get("size")
        else:
            sha, size = sha_of_url(url)
        files.append({"path": rel, "url": url, "size": size, "sha256": sha})
    total = sum(x["size"] for x in files)
    out[mid] = {"repo": repo, "revision": rev, "license": (info.get("cardData") or {}).get("license"), "total": total, "files": files}
    print(f"{mid}: {len(files)} files, {total/1e9:.2f} GB, rev {rev[:10]}")

os.makedirs("catalog", exist_ok=True)
json.dump(out, open("catalog/files.json", "w"), indent=1)
