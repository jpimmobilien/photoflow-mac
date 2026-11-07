#!/usr/bin/env python3
"""Draws the PhotoFlow app icon (macOS squircle grid) and packs a native .icns (PNG-based entries)."""
import struct, io, sys, math
from PIL import Image, ImageDraw, ImageFilter, ImageChops

S = 4096  # supersampled canvas (1024 × 4)
def sc(v): return int(v * S / 1024)

def gradient(size, c1, c2, angle_deg=135):
    w, h = size
    g = Image.new('RGB', size)
    a = math.radians(angle_deg)
    dx, dy = math.cos(a), math.sin(a)
    import numpy as np
    yy, xx = np.mgrid[0:h, 0:w].astype('float32')
    t = ((xx / w - 0.5) * dx + (yy / h - 0.5) * dy) / (abs(dx) * 0.5 + abs(dy) * 0.5) * 0.5 + 0.5
    t = t.clip(0, 1)[..., None]
    c1 = np.array(c1, 'float32'); c2 = np.array(c2, 'float32')
    arr = (c1 * (1 - t) + c2 * t).astype('uint8')
    return Image.fromarray(arr, 'RGB')

def rounded_mask(size, box, radius):
    m = Image.new('L', size, 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m

def draw_icon():
    canvas = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    # macOS icon grid: 824 × 824 body, 100 px margin, corner radius ≈ 185
    body = (sc(100), sc(100), sc(924), sc(924))
    mask = rounded_mask((S, S), body, sc(185))
    # shadow
    shadow = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    sh = rounded_mask((S, S), (body[0], body[1] + sc(14), body[2], body[3] + sc(14)), sc(185))
    shadow.putalpha(sh.point(lambda v: int(v * 0.35)))
    shadow = shadow.filter(ImageFilter.GaussianBlur(sc(18)))
    canvas = Image.alpha_composite(canvas, shadow)
    bg = gradient((S, S), (108, 76, 255), (0, 182, 255), 125).convert('RGBA')
    # soft highlight at the top
    hl = gradient((S, S), (255, 255, 255), (0, 0, 0), 90).convert('L').point(lambda v: int(max(0, v - 150) * 0.55))
    white = Image.new('RGBA', (S, S), (255, 255, 255, 0)); white.putalpha(hl)
    bg = Image.alpha_composite(bg, white)
    bg.putalpha(mask)
    canvas = Image.alpha_composite(canvas, bg)

    # Photo card (tilted) – white frame with landscape
    card = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(card)
    cx, cy = sc(500), sc(540)
    w, h = sc(470), sc(370)
    box = (cx - w // 2, cy - h // 2, cx + w // 2, cy + h // 2)
    d.rounded_rectangle(box, radius=sc(46), fill=(255, 255, 255, 255))
    inner = (box[0] + sc(30), box[1] + sc(30), box[2] - sc(30), box[3] - sc(30))
    sky = gradient((inner[2] - inner[0], inner[3] - inner[1]), (255, 196, 120), (255, 120, 150), 90).convert('RGBA')
    im = Image.new('RGBA', (S, S), (0, 0, 0, 0)); im.paste(sky, inner[:2])
    imask = rounded_mask((S, S), inner, sc(24))
    # mountains
    md = ImageDraw.Draw(im)
    x0, y0, x1, y1 = inner
    md.polygon([(x0, y1), (x0 + (x1 - x0) * 0.35, y0 + (y1 - y0) * 0.38), (x0 + (x1 - x0) * 0.62, y1)], fill=(76, 60, 200, 255))
    md.polygon([(x0 + (x1 - x0) * 0.38, y1), (x0 + (x1 - x0) * 0.72, y0 + (y1 - y0) * 0.5), (x1, y0 + (y1 - y0) * 0.78), (x1, y1)], fill=(40, 120, 230, 255))
    sun_r = sc(34)
    sx, sy = x0 + (x1 - x0) * 0.74, y0 + (y1 - y0) * 0.28
    md.ellipse((sx - sun_r, sy - sun_r, sx + sun_r, sy + sun_r), fill=(255, 250, 230, 255))
    im.putalpha(ImageChops.multiply(im.getchannel('A'), imask))
    card = Image.alpha_composite(card, im)
    card = card.rotate(-7, resample=Image.BICUBIC, center=(cx, cy))
    cshadow = Image.new('RGBA', (S, S), (20, 10, 60, 0))
    cshadow.putalpha(card.getchannel('A').point(lambda v: int(v * 0.35)))
    cshadow = cshadow.filter(ImageFilter.GaussianBlur(sc(16)))
    cshadow = ImageChops.offset(cshadow, 0, sc(16))
    canvas = Image.alpha_composite(canvas, cshadow)
    canvas = Image.alpha_composite(canvas, card)

    # Sparkle (four-pointed star) – "intelligent" enhancement
    sp = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    spd = ImageDraw.Draw(sp)
    def star(x, y, r, color):
        pts = []
        for k in range(8):
            ang = math.pi / 4 * k - math.pi / 2
            rr = r if k % 2 == 0 else r * 0.28
            pts.append((x + rr * math.cos(ang), y + rr * math.sin(ang)))
        spd.polygon(pts, fill=color)
    star(sc(770), sc(262), sc(108), (255, 255, 255, 255))
    star(sc(860), sc(400), sc(48), (255, 255, 255, 235))
    star(sc(655), sc(190), sc(36), (255, 255, 255, 220))
    glow = sp.filter(ImageFilter.GaussianBlur(sc(14)))
    canvas = Image.alpha_composite(canvas, glow)
    canvas = Image.alpha_composite(canvas, sp)
    return canvas.resize((1024, 1024), Image.LANCZOS)

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
    out_dir = sys.argv[1]
    icon = draw_icon()
    icon.save(f'{out_dir}/AppIcon-1024.png')
    pack_icns(icon, f'{out_dir}/AppIcon.icns')
    print('ok')
