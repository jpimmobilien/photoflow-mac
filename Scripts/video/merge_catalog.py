#!/usr/bin/env python3
"""Adds/updates entries in the embedded catalog (Sources/PhotoFlow/AI/AIModelCatalogData.swift) from
catalog JSON files in the files.json format ({id: {revision, files:[{path,url,size,sha256}]}}).
usage: merge_catalog.py video-files.json runtime.json ..."""
import json, re, sys
fn = "Sources/PhotoFlow/AI/AIModelCatalogData.swift"
src = open(fn).read()
m = re.search(r'static let json = #"""\n(.*)\n"""#', src, re.S)
cat = json.loads(m.group(1))
for path in sys.argv[1:]:
    for mid, e in json.load(open(path)).items():
        cat[mid] = {"revision": e["revision"],
                    "files": [{"path": f["path"], "url": f["url"], "size": f["size"], "sha256": f["sha256"]} for f in e["files"]]}
        print(f"{mid}: {len(e['files'])} files, {sum(f['size'] for f in e['files'])/1e9:.2f} GB")
payload = json.dumps(cat, separators=(",", ":"), sort_keys=True)
assert '"""' not in payload
open(fn, "w").write(src[:m.start(1)] + payload + src[m.end(1):])
