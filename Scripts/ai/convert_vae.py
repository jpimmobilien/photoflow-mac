#!/usr/bin/env python3
"""Converts the Stable Diffusion 1.x/2.x autoencoder (stabilityai/sd-vae-ft-mse, MIT licence) to Core ML in FLOAT32.

Why: Apple's Core ML VAE models are float16. On the CPU (x86 and Apple Silicon) Core ML computes them with wrong
values (measured with `PhotoFlow --qa ai-diag`: CPU outputs agree with each other but deviate by up to 0.5 / 7.5 from
the GPU and decode to uniform grey images). A float32 VAE is correct on every compute unit.

The packages use the same interface as Apple's (so the Swift pipeline can load them unchanged):
  VAEDecoder: input "z" [1,4,64,64] (latents / 0.18215)  -> output "image" [1,3,512,512] in [-1, 1]
  VAEEncoder: input "x" [1,3,512,512] in [-1, 1]          -> output "moments" [1,8,64,64] (mean | logvar)
Output: sd-vae-fp32.mlpackage.zip (VAEDecoder.mlpackage + VAEEncoder.mlpackage) + vae-manifest.json"""
import hashlib, json, os, shutil, subprocess
import numpy as np
import torch
import coremltools as ct
from diffusers import AutoencoderKL

REPO = "stabilityai/sd-vae-ft-mse"
vae = AutoencoderKL.from_pretrained(REPO, torch_dtype=torch.float32).eval()


class Dec(torch.nn.Module):
    def __init__(self, v):
        super().__init__(); self.v = v
    def forward(self, z):
        return self.v.decoder(self.v.post_quant_conv(z))


class Enc(torch.nn.Module):
    def __init__(self, v):
        super().__init__(); self.v = v
    def forward(self, x):
        return self.v.quant_conv(self.v.encoder(x))


def convert(module, name, inp_name, shape, out_name):
    ex = torch.randn(*shape)
    with torch.no_grad():
        traced = torch.jit.trace(module, ex)
        ref = module(ex).numpy()
    ml = ct.convert(traced, convert_to="mlprogram", inputs=[ct.TensorType(name=inp_name, shape=shape)],
                    outputs=[ct.TensorType(name=out_name)], compute_precision=ct.precision.FLOAT32,
                    minimum_deployment_target=ct.target.macOS13)
    ml.short_description = f"Stable Diffusion VAE {name} (sd-vae-ft-mse, float32) – converted by PhotoFlow"
    ml.license = "MIT (stabilityai/sd-vae-ft-mse)"
    ml.save(f"vae/{name}.mlpackage")
    print(name, "converted; torch output", ref.shape, float(ref.mean()), float(ref.std()))


os.makedirs("vae", exist_ok=True)
convert(Dec(vae), "VAEDecoder", "z", (1, 4, 64, 64), "image")
convert(Enc(vae), "VAEEncoder", "x", (1, 3, 512, 512), "moments")
subprocess.check_call(["zip", "-qr", "../sd-vae-fp32.mlpackage.zip", "VAEDecoder.mlpackage", "VAEEncoder.mlpackage"], cwd="vae")


def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""): h.update(b)
    return h.hexdigest()


from huggingface_hub import HfApi
rev = HfApi().model_info(REPO).sha
m = {"sd-vae-fp32": {"file": "sd-vae-fp32.mlpackage.zip", "size": os.path.getsize("sd-vae-fp32.mlpackage.zip"),
                     "sha256": sha("sd-vae-fp32.mlpackage.zip"), "source": f"https://huggingface.co/{REPO}",
                     "weights_sha256": rev, "license": "MIT"}}
json.dump(m, open("vae-manifest.json", "w"), indent=1)
print(m)
