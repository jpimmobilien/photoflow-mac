#!/usr/bin/env python3
"""End-to-end test of the PhotoFlow video engine through its JSON-lines worker – the same protocol
the app uses. Real models, real inference, no mocks.

usage: ci_video_test.py --suite t2v|ti2v|vace --model-dir DIR --out DIR [--width W --height H --frames N --steps S]
Writes PNG frames, an MP4 (ffmpeg, if present), a contact sheet and results.json to --out."""
import argparse, json, os, subprocess, sys, threading, time
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ENGINE = os.path.join(ROOT, "Resources", "VideoEngine")


class Worker:
    def __init__(self):
        env = dict(os.environ, PYTHONPATH=ENGINE, PYTHONUNBUFFERED="1")
        self.p = subprocess.Popen([sys.executable, "-m", "photoflow_video.worker"], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=sys.stderr, text=True, env=env, bufsize=1)
        self.n = 0

    def send(self, obj):
        self.p.stdin.write(json.dumps(obj) + "\n")
        self.p.stdin.flush()

    def call(self, cmd, on_event=None, **kw):
        self.n += 1
        rid = self.n
        self.send({"id": rid, "cmd": cmd, **kw})
        while True:
            line = self.p.stdout.readline()
            if not line:
                raise RuntimeError("worker exited")
            ev = json.loads(line)
            if on_event:
                on_event(ev)
            if ev.get("event") == "progress":
                print(f"   step {ev['step']}/{ev['total']}  {ev['elapsed']:.0f}s", flush=True)
                continue
            if ev.get("event") == "status":
                print(f"   … {ev.get('stage')}: {ev.get('message')}", flush=True)
                continue
            if ev.get("event") in ("result", "ready", "error", "cancelled", "bye"):
                return ev


def contact_sheet(folder, dest, n=6):
    names = sorted(x for x in os.listdir(folder) if x.endswith(".png"))
    if not names:
        return
    pick = [names[round(i * (len(names) - 1) / (n - 1))] for i in range(n)]
    ims = [Image.open(os.path.join(folder, x)) for x in pick]
    w, h = ims[0].size
    sheet = Image.new("RGB", (w * 3, h * 2), "white")
    for i, im in enumerate(ims):
        sheet.paste(im, ((i % 3) * w, (i // 3) * h))
    sheet.save(dest)


def to_mp4(folder, dest, fps):
    try:
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-framerate", str(fps), "-i",
                        os.path.join(folder, "frame_%05d.png"), "-c:v", "libx264", "-pix_fmt", "yuv420p", dest],
                       check=True)
    except Exception as e:  # noqa
        print("   (no mp4:", e, ")")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--suite", required=True)
    ap.add_argument("--model-dir", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--width", type=int, default=480)
    ap.add_argument("--height", type=int, default=288)
    ap.add_argument("--frames", type=int, default=25)
    ap.add_argument("--steps", type=int, default=12)
    ap.add_argument("--image", default=os.path.join(ROOT, "Tests", "Fixtures", "video_source.jpg"))
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    results = {"suite": a.suite, "tests": []}

    def record(name, ok, **info):
        print(f"{'PASS' if ok else 'FAIL'} {name} {json.dumps(info)[:400]}", flush=True)
        results["tests"].append({"name": name, "passed": bool(ok), **info})

    w = Worker()
    t0 = time.time()
    hello = w.call("hello")
    record("worker start", hello.get("event") == "ready", **hello, seconds=round(time.time() - t0, 1))
    kind = {"t2v": "wan-t2v", "ti2v": "wan-ti2v", "vace": "wan-vace"}[a.suite]
    t0 = time.time()
    r = w.call("load", model_id=kind, path=a.model_dir, kind=kind)
    record("load model", r.get("event") == "result", **r)

    common = dict(width=a.width, height=a.height, steps=a.steps, seed=42,
                  negative_prompt="blurry, low quality, distorted, static, worst quality, watermark, text")

    def gen(name, cmd, **kw):
        out = os.path.join(a.out, name)
        args = {**common, **kw}
        r = w.call(cmd, out=out, **args)
        ok = r.get("event") == "result" and r.get("valid")
        record(name, ok, **{k: v for k, v in r.items() if k not in ("id",)})
        if r.get("event") == "result":
            contact_sheet(out, os.path.join(a.out, f"{name}_sheet.png"))
            to_mp4(out, os.path.join(a.out, f"{name}.mp4"), 16 if a.suite != "ti2v" else 24)
        return out, r

    if a.suite == "t2v":
        prompt = ("A red vintage car driving along a coastal road at sunset, the camera follows from the side, "
                  "realistic lighting, smooth motion, cinematic")
        out, _ = gen("t2v", "t2v", prompt=prompt, frames=a.frames)
        # reproducibility: same seed → same first frame
        out2, _ = gen("t2v_repeat", "t2v", prompt=prompt, frames=a.frames)
        f1 = Image.open(os.path.join(out, "frame_00000.png")); f2 = Image.open(os.path.join(out2, "frame_00000.png"))
        import numpy as np
        diff = float(np.abs(np.asarray(f1, dtype=np.float32) - np.asarray(f2, dtype=np.float32)).mean() / 255)
        record("reproducible (same seed)", diff < 0.01, mean_abs_diff=diff)
        # video to video on the generated clip
        gen("v2v", "v2v", prompt="The same scene in winter, snow covered road and hills, overcast light",
            video_frames=out, strength=0.6)
        # cancel after two steps, then generate again
        seen = {"n": 0}

        def on_ev(ev):
            if ev.get("event") == "progress":
                seen["n"] += 1
                if seen["n"] == 2:
                    w.send({"id": 999, "cmd": "cancel"})
        r = w.call("t2v", on_event=on_ev, out=os.path.join(a.out, "cancelled"), prompt="ocean waves",
                   frames=a.frames, **common)
        record("cancel", r.get("event") == "cancelled", steps_before_cancel=seen["n"])
        gen("after_cancel", "t2v", prompt="Ocean waves rolling onto a sandy beach, golden hour", frames=a.frames)
    elif a.suite == "ti2v":
        gen("t2v_5b", "t2v", prompt="A sailboat gliding across a calm lake in the morning mist, gentle camera pan",
            frames=a.frames)
        gen("i2v", "i2v", image=a.image, prompt="The birds slowly turn their heads, leaves move in the wind, "
            "subtle natural motion, camera slowly pushes in", frames=a.frames)
    elif a.suite == "vace":
        # Build a test clip: a photo panned slowly (real content, real camera motion); remove a region.
        import numpy as np
        src = Image.open(a.image).convert("RGB")
        clip, mask = os.path.join(a.out, "clip"), os.path.join(a.out, "clip_mask")
        os.makedirs(clip, exist_ok=True); os.makedirs(mask, exist_ok=True)
        W, H = src.size
        cw, ch = int(W * 0.8), int(H * 0.8)
        for i in range(a.frames):
            x = int((W - cw) * i / max(1, a.frames - 1))
            fr = src.crop((x, (H - ch) // 2, x + cw, (H - ch) // 2 + ch)).resize((a.width, a.height), Image.LANCZOS)
            fr.save(os.path.join(clip, f"f_{i:05d}.png"))
            m = Image.new("L", (a.width, a.height), 0)
            # a moving rectangle region to regenerate (stands in for a tracked object mask)
            mx = int(a.width * (0.55 - 0.2 * i / max(1, a.frames - 1)))
            m.paste(255, (mx, int(a.height * 0.25), mx + a.width // 5, int(a.height * 0.75)))
            m.save(os.path.join(mask, f"m_{i:05d}.png"))
        out, r = gen("vace_fill", "vace", prompt="lush green tropical leaves, soft background bokeh",
                     video_frames=clip, mask_frames=mask, frames=a.frames)
        if r.get("event") == "result":
            # outside the mask the result must follow the source clip
            diffs = []
            for i in range(a.frames):
                o = np.asarray(Image.open(os.path.join(out, f"frame_{i:05d}.png")).convert("RGB"), dtype=np.float32)
                s = np.asarray(Image.open(os.path.join(clip, f"f_{i:05d}.png")), dtype=np.float32)
                m = np.asarray(Image.open(os.path.join(mask, f"m_{i:05d}.png")), dtype=np.float32) > 0
                keep = ~m
                diffs.append(float(np.abs(o[keep] - s[keep]).mean() / 255))
            record("vace outside mask follows source", max(diffs) < 0.08, mean=float(np.mean(diffs)), max=max(diffs))
    r = w.call("unload")
    record("unload", r.get("event") == "result", **r)
    w.call("quit")
    results["passed"] = all(t["passed"] for t in results["tests"])
    json.dump(results, open(os.path.join(a.out, "results.json"), "w"), indent=1)
    print("ALL PASS" if results["passed"] else "SOME FAILED")
    sys.exit(0 if results["passed"] else 1)


if __name__ == "__main__":
    main()
