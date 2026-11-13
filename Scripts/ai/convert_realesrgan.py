#!/usr/bin/env python3
"""Converts the official Real-ESRGAN weights (BSD-3-Clause, github.com/xinntao/Real-ESRGAN releases) to Core ML.
The network definitions below follow BasicSR's RRDBNet / SRVGGNetCompact exactly (same parameter names), so the
official state dicts load with strict=True. Each model is converted for a fixed 256×256 RGB tile; PhotoFlow tiles
larger images with overlap. Output: models/<name>.mlpackage.zip + models/manifest.json (sizes, SHA-256)."""
import hashlib, json, os, shutil, sys, urllib.request
import numpy as np, torch, torch.nn as nn, torch.nn.functional as F
import coremltools as ct

WEIGHTS = {
    "realesrgan-x4plus": ("https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth", "rrdb", 4),
    "realesrgan-x2plus": ("https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth", "rrdb", 2),
    "realesr-general-x4v3": ("https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth", "srvgg", 4),
}
TILE = 256

class ResidualDenseBlock(nn.Module):
    def __init__(self, num_feat=64, num_grow_ch=32):
        super().__init__()
        self.conv1 = nn.Conv2d(num_feat, num_grow_ch, 3, 1, 1)
        self.conv2 = nn.Conv2d(num_feat + num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv3 = nn.Conv2d(num_feat + 2 * num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv4 = nn.Conv2d(num_feat + 3 * num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv5 = nn.Conv2d(num_feat + 4 * num_grow_ch, num_feat, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(negative_slope=0.2, inplace=True)
    def forward(self, x):
        x1 = self.lrelu(self.conv1(x))
        x2 = self.lrelu(self.conv2(torch.cat((x, x1), 1)))
        x3 = self.lrelu(self.conv3(torch.cat((x, x1, x2), 1)))
        x4 = self.lrelu(self.conv4(torch.cat((x, x1, x2, x3), 1)))
        x5 = self.conv5(torch.cat((x, x1, x2, x3, x4), 1))
        return x5 * 0.2 + x

class RRDB(nn.Module):
    def __init__(self, num_feat, num_grow_ch=32):
        super().__init__()
        self.rdb1 = ResidualDenseBlock(num_feat, num_grow_ch)
        self.rdb2 = ResidualDenseBlock(num_feat, num_grow_ch)
        self.rdb3 = ResidualDenseBlock(num_feat, num_grow_ch)
    def forward(self, x):
        out = self.rdb3(self.rdb2(self.rdb1(x)))
        return out * 0.2 + x

class RRDBNet(nn.Module):
    def __init__(self, num_in_ch=3, num_out_ch=3, scale=4, num_feat=64, num_block=23, num_grow_ch=32):
        super().__init__()
        self.scale = scale
        if scale == 2: num_in_ch = num_in_ch * 4
        elif scale == 1: num_in_ch = num_in_ch * 16
        self.conv_first = nn.Conv2d(num_in_ch, num_feat, 3, 1, 1)
        self.body = nn.Sequential(*[RRDB(num_feat, num_grow_ch) for _ in range(num_block)])
        self.conv_body = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_up1 = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_up2 = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_hr = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_last = nn.Conv2d(num_feat, num_out_ch, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(negative_slope=0.2, inplace=True)
    def forward(self, x):
        if self.scale == 2: feat = F.pixel_unshuffle(x, 2)
        elif self.scale == 1: feat = F.pixel_unshuffle(x, 4)
        else: feat = x
        feat = self.conv_first(feat)
        body_feat = self.conv_body(self.body(feat))
        feat = feat + body_feat
        feat = self.lrelu(self.conv_up1(F.interpolate(feat, scale_factor=2, mode="nearest")))
        feat = self.lrelu(self.conv_up2(F.interpolate(feat, scale_factor=2, mode="nearest")))
        return self.conv_last(self.lrelu(self.conv_hr(feat)))

class SRVGGNetCompact(nn.Module):
    def __init__(self, num_in_ch=3, num_out_ch=3, num_feat=64, num_conv=32, upscale=4):
        super().__init__()
        self.upscale = upscale
        self.body = nn.ModuleList()
        self.body.append(nn.Conv2d(num_in_ch, num_feat, 3, 1, 1))
        self.body.append(nn.PReLU(num_parameters=num_feat))
        for _ in range(num_conv):
            self.body.append(nn.Conv2d(num_feat, num_feat, 3, 1, 1))
            self.body.append(nn.PReLU(num_parameters=num_feat))
        self.body.append(nn.Conv2d(num_feat, num_out_ch * upscale * upscale, 3, 1, 1))
        self.upsampler = nn.PixelShuffle(upscale)
    def forward(self, x):
        out = x
        for layer in self.body: out = layer(out)
        out = self.upsampler(out)
        return out + F.interpolate(x, scale_factor=self.upscale, mode="nearest")

class ToImage(nn.Module):
    """[0,1] RGB in → [0,255] RGB out (so Core ML can return an image directly)."""
    def __init__(self, net): super().__init__(); self.net = net
    def forward(self, x): return torch.clamp(self.net(x), 0.0, 1.0) * 255.0

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""): h.update(b)
    return h.hexdigest()

def main():
    os.makedirs("models", exist_ok=True); os.makedirs("weights", exist_ok=True)
    manifest = {}
    for name, (url, kind, scale) in WEIGHTS.items():
        wpath = f"weights/{os.path.basename(url)}"
        if not os.path.exists(wpath): urllib.request.urlretrieve(url, wpath)
        sd = torch.load(wpath, map_location="cpu")
        sd = sd.get("params_ema", sd.get("params", sd))
        net = RRDBNet(scale=scale) if kind == "rrdb" else SRVGGNetCompact(upscale=scale)
        net.load_state_dict(sd, strict=True)
        net.eval()
        model = ToImage(net).eval()
        example = torch.rand(1, 3, TILE, TILE)
        with torch.no_grad():
            traced = torch.jit.trace(model, example)
            ref = model(example)
        print(name, "torch output", tuple(ref.shape), float(ref.min()), float(ref.max()))
        ml = ct.convert(traced,
                        inputs=[ct.ImageType(name="input", shape=(1, 3, TILE, TILE), scale=1.0 / 255.0, color_layout=ct.colorlayout.RGB)],
                        outputs=[ct.ImageType(name="output", color_layout=ct.colorlayout.RGB)],
                        minimum_deployment_target=ct.target.macOS13,
                        compute_precision=ct.precision.FLOAT16,
                        convert_to="mlprogram")
        ml.author = "Xintao Wang et al. (Real-ESRGAN); Core ML conversion by PhotoFlow"
        ml.license = "BSD-3-Clause"
        ml.short_description = f"Real-ESRGAN {name} ×{scale}, {TILE}×{TILE} tile"
        ml.user_defined_metadata["photoflow.scale"] = str(scale)
        ml.user_defined_metadata["photoflow.tile"] = str(TILE)
        ml.user_defined_metadata["photoflow.source"] = url
        ml.user_defined_metadata["photoflow.weights_sha256"] = sha256(wpath)
        pkg = f"models/{name}.mlpackage"
        if os.path.exists(pkg): shutil.rmtree(pkg)
        ml.save(pkg)
        z = shutil.make_archive(f"models/{name}.mlpackage", "zip", "models", f"{name}.mlpackage")
        manifest[name] = {"file": os.path.basename(z), "size": os.path.getsize(z), "sha256": sha256(z),
                          "scale": scale, "tile": TILE, "source": url, "weights_sha256": sha256(wpath), "license": "BSD-3-Clause"}
        print(name, manifest[name])
    json.dump(manifest, open("models/manifest.json", "w"), indent=1)

if __name__ == "__main__":
    main()
