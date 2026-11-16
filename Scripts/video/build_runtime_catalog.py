#!/usr/bin/env python3
"""Builds the download list for PhotoFlow's video engine runtime (Apple Silicon, macOS 14+):
a relocatable CPython 3.12 build (python-build-standalone) plus every wheel pinned in
requirements-macos-arm64.lock. Each file gets URL, size and SHA-256 from the publisher's own metadata
(PyPI JSON API, the python-build-standalone release checksums); the SHA-256 must match the lock file's
hashes. PhotoFlow downloads these files with its verified model downloader and installs the wheels
offline (pip --no-index), so pip itself never touches the network.

usage: build_runtime_catalog.py LOCKFILE EXCLUDE_NEWER(YYYY-MM-DD) OUT.json"""
import json, re, sys, urllib.request
from packaging.tags import cpython_tags, compatible_tags, mac_platforms
from packaging.utils import parse_wheel_filename

lock, exclude_newer, out = sys.argv[1:4]
UA = {"User-Agent": "photoflow-runtime-catalog"}


def get(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r:
        return r.read()


# Pins and their allowed hashes from the uv lock
pins, hashes, cur = {}, {}, None
for line in open(lock):
    m = re.match(r"^([a-z0-9][a-z0-9._-]*)==([^\s\\]+)", line)
    if m:
        cur = m.group(1); pins[cur] = m.group(2); hashes[cur] = set()
        continue
    for h in re.findall(r"--hash=sha256:([0-9a-f]{64})", line):
        if cur:
            hashes[cur].add(h)

# Target: CPython 3.12, macOS 14 arm64
platforms = list(mac_platforms((14, 0), "arm64"))
tags = list(cpython_tags((3, 12), abis=["cp312"], platforms=platforms)) + list(compatible_tags((3, 12), "cp312", platforms))
rank = {t: i for i, t in enumerate(tags)}

files = []
for name, ver in sorted(pins.items()):
    meta = json.loads(get(f"https://pypi.org/pypi/{name}/{ver}/json"))
    best = None
    for u in meta["urls"]:
        if u["packagetype"] != "bdist_wheel":
            continue
        _, _, _, wtags = parse_wheel_filename(u["filename"])
        r = min((rank[t] for t in wtags if t in rank), default=None)
        if r is not None and (best is None or r < best[0]):
            best = (r, u)
    if best is None:
        sys.exit(f"no macOS arm64 / cp312 wheel for {name}=={ver}")
    u = best[1]
    sha = u["digests"]["sha256"]
    if hashes.get(name) and sha not in hashes[name]:
        sys.exit(f"{u['filename']}: SHA-256 not in lock file")
    files.append({"path": "wheels/" + u["filename"], "url": u["url"], "size": u["size"], "sha256": sha})
    print(f"{u['size']/1e6:8.1f} MB  {u['filename']}")

# python-build-standalone: newest release published before EXCLUDE_NEWER with a CPython 3.12 install_only build
rels = json.loads(get("https://api.github.com/repos/astral-sh/python-build-standalone/releases?per_page=40"))
pick = None
for rel in rels:
    if rel["draft"] or rel["prerelease"] or rel["published_at"][:10] >= exclude_newer:
        continue
    for a in rel["assets"]:
        if re.match(r"cpython-3\.12\.\d+\+\d+-aarch64-apple-darwin-install_only_stripped\.tar\.gz$", a["name"]):
            pick = (rel, a)
            break
    if pick:
        break
if not pick:
    sys.exit("no python-build-standalone release found")
rel, asset = pick
sums = get(next(a["browser_download_url"] for a in rel["assets"] if a["name"] == "SHA256SUMS")).decode()
sha = next(l.split()[0] for l in sums.splitlines() if l.strip().endswith(asset["name"]))
files.insert(0, {"path": "python/" + asset["name"], "url": asset["browser_download_url"], "size": asset["size"], "sha256": sha})
print(f"{asset['size']/1e6:8.1f} MB  {asset['name']} ({rel['tag_name']})")

total = sum(f["size"] for f in files)
json.dump({"video-runtime": {"repo": "pypi.org + astral-sh/python-build-standalone", "revision": f"python {rel['tag_name']} · torch {pins.get('torch')} · diffusers {pins.get('diffusers')}",
                             "total": total, "files": files}}, open(out, "w"), indent=1)
print(f"runtime: {len(files)} files, {total/1e6:.0f} MB")
