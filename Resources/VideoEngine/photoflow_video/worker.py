"""JSON-lines worker. PhotoFlow starts `python -m photoflow_video.worker` and writes one JSON object
per line to stdin; the worker answers with JSON lines on stdout (stderr is free-form log).

Requests ({"id": …, "cmd": …}):
  hello                                   → {"event":"ready", versions, device}
  load      {model_id, path, kind}        → {"event":"result", ...}
  t2v       {prompt, negative_prompt, width, height, frames, steps, guidance, seed, flow_shift?, out}
  i2v       {... image}
  v2v       {... video_frames, strength}
  vace      {... video_frames, mask_frames, reference_images?, conditioning_scale?}
  unload, memory, quit
  cancel    (may arrive while a job runs; read by a background thread)

Every generation writes PNG frames to `out` and answers
  {"event":"result","frames":n,"seconds":…,"valid":bool,"metrics":{…},"reasons":[…]}.
Progress: {"event":"progress","step":i,"total":n,"elapsed":s}. Errors: {"event":"error","message":…}."""
import json
import queue
import sys
import threading
import time
import traceback

_out_lock = threading.Lock()


def emit(obj, req_id=None):
    if req_id is not None and "id" not in obj:
        obj = {"id": req_id, **obj}
    line = json.dumps(obj, separators=(",", ":"))
    with _out_lock:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


def main():
    jobs = queue.Queue()
    state = {"engine": None, "current": None}

    def reader():
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                req = json.loads(line)
            except json.JSONDecodeError:
                emit({"event": "error", "message": "invalid JSON"})
                continue
            if req.get("cmd") == "cancel":
                if state["engine"] is not None:
                    state["engine"].cancel_requested = True
                emit({"event": "cancel-ack"}, req.get("id"))
                continue
            jobs.put(req)
        jobs.put({"cmd": "quit"})

    threading.Thread(target=reader, daemon=True).start()

    # Heavy imports after the reader runs so that "hello" is answered quickly even on a cold start.
    from .engine import Cancelled, VideoEngine, memory_info, save_frames
    from . import validate, attention, __version__

    while True:
        req = jobs.get()
        cmd = req.get("cmd")
        rid = req.get("id")
        current_id = {"v": rid}

        def scoped_emit(obj):
            emit(obj, current_id["v"])

        try:
            if cmd == "quit":
                emit({"event": "bye"}, rid)
                return
            if state["engine"] is None:
                state["engine"] = VideoEngine(scoped_emit, device=req.get("device"), dtype=req.get("dtype"))
            eng = state["engine"]
            eng.emit = scoped_emit
            if cmd == "hello":
                import torch, diffusers, transformers
                emit({"event": "ready", "engine": __version__, "torch": torch.__version__,
                      "diffusers": diffusers.__version__, "transformers": transformers.__version__,
                      "device": eng.device.type, "dtype": str(eng.dtype).replace("torch.", ""),
                      "mps": bool(torch.backends.mps.is_available())}, rid)
            elif cmd == "load":
                emit({"event": "result", **eng.load(req["model_id"], req["path"], req["kind"])}, rid)
            elif cmd in ("t2v", "i2v", "v2v", "vace"):
                fn = {"t2v": eng.text_to_video, "i2v": eng.image_to_video,
                      "v2v": eng.video_to_video, "vace": eng.vace}[cmd]
                frames, seconds = fn(req)
                ok, metrics, reasons = validate.check(frames)
                save_frames(frames, req["out"])
                emit({"event": "result", "frames": int(len(frames)), "width": int(frames.shape[2]),
                      "height": int(frames.shape[1]), "seconds": round(seconds, 2), "valid": ok,
                      "metrics": metrics, "reasons": reasons, "attention": dict(attention.stats),
                      **memory_info(eng.device)}, rid)
            elif cmd == "unload":
                eng.unload()
                emit({"event": "result", "unloaded": True, **memory_info(eng.device)}, rid)
            elif cmd == "memory":
                emit({"event": "result", **memory_info(eng.device)}, rid)
            else:
                emit({"event": "error", "message": f"unknown command {cmd}"}, rid)
        except Cancelled:
            emit({"event": "cancelled"}, rid)
        except MemoryError:
            state["engine"] and state["engine"].unload()
            emit({"event": "error", "kind": "memory", "message": "not enough memory"}, rid)
        except Exception as e:  # noqa
            traceback.print_exc(file=sys.stderr)
            msg = str(e)
            kind = "memory" if ("out of memory" in msg.lower() or "MPS backend out of memory" in msg) else "failure"
            emit({"event": "error", "kind": kind, "message": msg[:2000]}, rid)


if __name__ == "__main__":
    main()
