"""Model loading and generation for the PhotoFlow video engine.

Supported model kinds (all Wan, Apache 2.0, diffusers layout on disk):
  wan-t2v   Wan2.1-T2V-1.3B      text→video, video→video
  wan-ti2v  Wan2.2-TI2V-5B       text→video, image→video
  wan-vace  Wan2.1-VACE-1.3B     masked video editing: fill/remove, expand, reference character

Memory strategy for unified memory: the 5.7B-parameter UMT5 text encoder is loaded only to encode
the prompt and released immediately; prompt embeddings are cached. Attention is chunked
(attention.py), the VAE decodes in tiles."""
import gc
import os
import time

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
os.environ.setdefault("DIFFUSERS_OFFLINE", "1")
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "0")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

import numpy as np  # noqa: E402
import torch  # noqa: E402

from . import attention  # noqa: E402

attention.install()

from PIL import Image  # noqa: E402


class Cancelled(Exception):
    pass


def pick_device(requested=None):
    if requested and requested != "auto":
        return torch.device(requested)
    if torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def empty_cache(device):
    gc.collect()
    if device.type == "mps":
        torch.mps.empty_cache()


def memory_info(device):
    info = {}
    try:
        import resource
        # ru_maxrss: bytes on macOS, kilobytes on Linux
        r = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        info["peak_rss_gb"] = round(r / (1 << 30) if os.uname().sysname == "Darwin" else r / (1 << 20), 2)
    except Exception:
        pass
    if device.type == "mps":
        info["mps_allocated_gb"] = round(torch.mps.current_allocated_memory() / (1 << 30), 2)
        info["mps_driver_gb"] = round(torch.mps.driver_allocated_memory() / (1 << 30), 2)
    return info


class VideoEngine:
    def __init__(self, emit, device=None, dtype=None):
        self.emit = emit
        self.device = pick_device(device)
        if dtype:
            self.dtype = getattr(torch, dtype)
        else:
            # bf16 on Apple GPUs (macOS 14+); full precision on CPU (bf16 matmuls are very slow without AMX)
            self.dtype = torch.bfloat16 if self.device.type == "mps" else torch.float32
        self.model_id = None
        self.kind = None
        self.path = None
        self.te_path = None
        self.transformer = None
        self.vae = None
        self.scheduler_config = None
        self.embed_cache = {}
        self.cancel_requested = False

    # ---------------------------------------------------------------- loading
    def load(self, model_id, path, kind, text_encoder_path=None):
        # The UMT5 text encoder + tokenizer live in a shared folder (one copy for all Wan models)
        self.te_path = text_encoder_path or path
        if self.model_id == model_id and self.transformer is not None:
            return {"loaded": model_id, "cached": True}
        self.unload()
        t0 = time.time()
        from diffusers import AutoencoderKLWan, WanTransformer3DModel
        from diffusers.models.transformers.transformer_wan_vace import WanVACETransformer3DModel
        self.emit({"event": "status", "stage": "load", "message": "transformer"})
        cls = WanVACETransformer3DModel if kind == "wan-vace" else WanTransformer3DModel
        self.transformer = cls.from_pretrained(path, subfolder="transformer", torch_dtype=self.dtype).to(self.device)
        self.emit({"event": "status", "stage": "load", "message": "vae"})
        # The Wan VAE is decoded in float32 (diffusers recommendation; bf16 decoding loses detail)
        self.vae = AutoencoderKLWan.from_pretrained(path, subfolder="vae", torch_dtype=torch.float32).to(self.device)
        self.vae.enable_tiling()
        self.model_id, self.kind, self.path = model_id, kind, path
        empty_cache(self.device)
        return {"loaded": model_id, "seconds": round(time.time() - t0, 1), "device": self.device.type,
                "dtype": str(self.dtype).replace("torch.", ""), **memory_info(self.device)}

    def unload(self):
        self.transformer = None
        self.vae = None
        self.model_id = None
        self.kind = None
        self.embed_cache.clear()
        empty_cache(self.device)

    # ---------------------------------------------------------------- prompts
    def encode(self, prompt, negative):
        key = (self.te_path, prompt, negative)
        if key in self.embed_cache:
            return self.embed_cache[key]
        from transformers import AutoTokenizer, UMT5EncoderModel
        from diffusers import WanPipeline
        t0 = time.time()
        self.emit({"event": "status", "stage": "text", "message": "encoding prompt"})
        tok = AutoTokenizer.from_pretrained(self.te_path, subfolder="tokenizer")
        # text encoder in bf16 everywhere: 11 GB instead of 22 GB; it runs once per prompt
        te = UMT5EncoderModel.from_pretrained(self.te_path, subfolder="text_encoder", torch_dtype=torch.bfloat16)
        te = te.to(self.device)
        helper = WanPipeline(tokenizer=tok, text_encoder=te, vae=None, transformer=None, scheduler=None)
        with torch.no_grad():
            pe, ne = helper.encode_prompt(prompt=prompt, negative_prompt=negative, do_classifier_free_guidance=True,
                                          num_videos_per_prompt=1, max_sequence_length=512, device=self.device,
                                          dtype=self.dtype)
        del helper, te, tok
        empty_cache(self.device)
        if len(self.embed_cache) > 8:
            self.embed_cache.clear()
        self.embed_cache[key] = (pe, ne)
        self.emit({"event": "status", "stage": "text", "message": f"prompt encoded in {time.time() - t0:.1f}s"})
        return pe, ne

    # ---------------------------------------------------------------- pipelines
    def _scheduler(self, flow_shift):
        from diffusers import UniPCMultistepScheduler
        sched = UniPCMultistepScheduler.from_pretrained(self.path, subfolder="scheduler")
        if flow_shift is not None:
            sched = UniPCMultistepScheduler.from_config(sched.config, flow_shift=flow_shift)
        return sched

    def _pipeline(self, cls, flow_shift, **extra):
        return cls(tokenizer=None, text_encoder=None, vae=self.vae, transformer=self.transformer,
                   scheduler=self._scheduler(flow_shift), **extra)

    def _callback(self, total, t_start):
        def cb(pipe, i, t, kwargs):
            if self.cancel_requested:
                raise Cancelled()
            now = time.time()
            self.emit({"event": "progress", "step": i + 1, "total": total, "elapsed": round(now - t_start, 2)})
            return {}
        return cb

    def _run(self, pipe, total_steps, **kwargs):
        self.cancel_requested = False
        t0 = time.time()
        gen = torch.Generator(device="cpu").manual_seed(int(kwargs.pop("seed")))
        with torch.no_grad():
            out = pipe(generator=gen, callback_on_step_end=self._callback(total_steps, t0),
                       output_type="np", **kwargs)
        frames = out.frames[0]
        frames = (np.clip(frames, 0, 1) * 255).round().astype(np.uint8)
        return frames, time.time() - t0

    def _common(self, req):
        pe, ne = self.encode(req.get("prompt", ""), req.get("negative_prompt", ""))
        return dict(prompt_embeds=pe, negative_prompt_embeds=ne, height=int(req["height"]), width=int(req["width"]),
                    num_inference_steps=int(req["steps"]), guidance_scale=float(req.get("guidance", 5.0)),
                    seed=req.get("seed", 0))

    def text_to_video(self, req):
        from diffusers import WanPipeline
        assert self.kind in ("wan-t2v", "wan-ti2v"), "model does not support text to video"
        pipe = self._pipeline(WanPipeline, req.get("flow_shift"), expand_timesteps=(self.kind == "wan-ti2v"))
        return self._run(pipe, int(req["steps"]), num_frames=int(req["frames"]), **self._common(req))

    def image_to_video(self, req):
        from diffusers import WanImageToVideoPipeline
        assert self.kind == "wan-ti2v", "model does not support image to video"
        pipe = self._pipeline(WanImageToVideoPipeline, req.get("flow_shift"), expand_timesteps=True)
        image = Image.open(req["image"]).convert("RGB").resize((int(req["width"]), int(req["height"])), Image.LANCZOS)
        return self._run(pipe, int(req["steps"]), image=image, num_frames=int(req["frames"]), **self._common(req))

    def video_to_video(self, req):
        from diffusers import WanVideoToVideoPipeline
        assert self.kind == "wan-t2v", "model does not support video to video"
        pipe = self._pipeline(WanVideoToVideoPipeline, req.get("flow_shift"))
        video = load_frames(req["video_frames"], int(req["width"]), int(req["height"]))
        strength = float(req.get("strength", 0.6))
        # diffusers runs int(steps*strength) steps
        steps = max(1, int(int(req["steps"]) * strength))
        return self._run(pipe, steps, video=video, strength=strength, **self._common(req))

    def vace(self, req):
        from diffusers import WanVACEPipeline
        assert self.kind == "wan-vace", "model does not support masked video editing"
        pipe = self._pipeline(WanVACEPipeline, req.get("flow_shift"))
        w, h = int(req["width"]), int(req["height"])
        video = load_frames(req["video_frames"], w, h)
        mask = load_frames(req["mask_frames"], w, h, mode="L")
        refs = [Image.open(p).convert("RGB") for p in req.get("reference_images", [])] or None
        # VACE convention: masked (white) pixels of the conditioning video are neutral grey
        video = [Image.composite(Image.new("RGB", (w, h), (128, 128, 128)), v, m) for v, m in zip(video, mask)]
        mask = [m.convert("RGB") for m in mask]  # the pipeline expects 3-channel masks (white = generate)
        return self._run(pipe, int(req["steps"]), video=video, mask=mask, reference_images=refs,
                         num_frames=len(video), conditioning_scale=float(req.get("conditioning_scale", 1.0)),
                         **self._common(req))


def load_frames(folder, w, h, mode="RGB"):
    names = sorted(n for n in os.listdir(folder) if n.lower().endswith((".png", ".jpg", ".jpeg")))
    out = []
    for n in names:
        im = Image.open(os.path.join(folder, n)).convert(mode)
        if im.size != (w, h):
            im = im.resize((w, h), Image.LANCZOS if mode == "RGB" else Image.NEAREST)
        out.append(im)
    return out


def save_frames(frames, folder):
    os.makedirs(folder, exist_ok=True)
    for i, f in enumerate(frames):
        Image.fromarray(f).save(os.path.join(folder, f"frame_{i:05d}.png"), compress_level=1)
