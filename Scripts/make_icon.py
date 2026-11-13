#!/usr/bin/env python3
"""Builds every macOS icon size from the binding PhotoFlow 2.0 icon artwork.

Source: Packaging/icon/AppIcon-source.png (the artwork exactly as supplied, on white).
The squircle body is cut out with a superellipse mask fitted to the artwork's own rim
(|x/a|^4.1 + |y/a|^4.1 = 1, centre 625.5, a = 545.5 px) – the artwork itself is not altered.
Outputs:
  Packaging/AppIcon-1024.png  macOS icon canvas (824 px body, 100 px grid margin, soft shadow)
  Packaging/AppIcon.icns      all sizes 16…1024 incl. @2x (PNG entries icp4…ic14)
  Resources/BrandMark.png     body only, transparent – used in-app (welcome, About, empty states)
"""
import io, struct, sys, os
import numpy as np
from PIL import Image, ImageFilter

C, R, N, SS = 625.5, 545.5, 4.1, 4

def cut_body(src):
    a = np.asarray(src.convert('RGB')).astype(np.float32)
    H, W, _ = a.shape
    yy, xx = np.mgrid[0:H * SS, 0:W * SS].astype(np.float32)
    xs, ys = (xx + 0.5) / SS - 0.5, (yy + 0.5) / SS - 0.5
    m = ((np.abs((xs - C) / R) ** N + np.abs((ys - C) / R) ** N) <= 1).astype(np.float32)
    m = m.reshape(H, SS, W, SS).mean(axis=(1, 3))
    x0, x1 = int(C - R - 1), int(C + R + 2)
    return Image.fromarray(np.dstack([a, m * 255])[x0:x1, x0:x1].astype(np.uint8), 'RGBA')

def canvas_1024(body):
    b = body.resize((824, 824), Image.LANCZOS)
    sh = Image.new('L', (1024, 1024), 0); sh.paste(b.split()[3], (100, 112))
    sh = sh.filter(ImageFilter.GaussianBlur(14)).point(lambda p: int(p * 0.30))
    out = Image.new('RGBA', (1024, 1024), (0, 0, 0, 0)); out.putalpha(sh)
    out = Image.composite(out, Image.new('RGBA', (1024, 1024), (0, 0, 0, 0)), sh)
    out.alpha_composite(b, (100, 100))
    return out

def pack_icns(img1024, path):
    entries = [('icp4', 16), ('icp5', 32), ('icp6', 64), ('ic07', 128), ('ic08', 256), ('ic09', 512), ('ic10', 1024),
               ('ic11', 32), ('ic12', 64), ('ic13', 256), ('ic14', 512)]
    chunks = b''
    for code, size in entries:
        buf = io.BytesIO()
        img1024.resize((size, size), Image.LANCZOS).save(buf, 'PNG', optimize=True)
        data = buf.getvalue()
        chunks += code.encode('ascii') + struct.pack('>I', len(data) + 8) + data
    with open(path, 'wb') as f:
        f.write(b'icns' + struct.pack('>I', len(chunks) + 8) + chunks)

if __name__ == '__main__':
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), '..')
    body = cut_body(Image.open(f'{root}/Packaging/icon/AppIcon-source.png'))
    icon = canvas_1024(body)
    icon.save(f'{root}/Packaging/AppIcon-1024.png')
    pack_icns(icon, f'{root}/Packaging/AppIcon.icns')
    body.resize((512, 512), Image.LANCZOS).save(f'{root}/Resources/BrandMark.png', optimize=True)
    print('ok')
