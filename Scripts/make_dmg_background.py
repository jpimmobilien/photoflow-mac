#!/usr/bin/env python3
"""DMG window background (660x420 @1x and @2x) in the PhotoFlow 2.0 palette: warm light grey,
soft sky/periwinkle and sun glows taken from the icon, brand mark, refined arrow."""
import sys, os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

def font(names, size):
    for n in names:
        for d in ['/usr/share/fonts', '/usr/local/share/fonts', os.path.expanduser('~/.fonts')]:
            for root, _, files in os.walk(d):
                if n in files:
                    return ImageFont.truetype(os.path.join(root, n), size)
    return ImageFont.load_default()

def render(s, root):
    W, H = 660 * s, 420 * s
    img = Image.new('RGBA', (W, H), (245, 243, 240, 255))           # warm very light grey
    glow = Image.new('RGBA', (W, H), (0, 0, 0, 0)); g = ImageDraw.Draw(glow)
    g.ellipse((-140 * s, -180 * s, 300 * s, 240 * s), fill=(110, 160, 255, 70))   # sky blue
    g.ellipse((420 * s, 180 * s, 820 * s, 560 * s), fill=(150, 125, 255, 60))     # periwinkle
    g.ellipse((470 * s, -120 * s, 720 * s, 120 * s), fill=(255, 190, 120, 45))    # sun
    glow = glow.filter(ImageFilter.GaussianBlur(90 * s))
    img = Image.alpha_composite(img, glow)
    d = ImageDraw.Draw(img)
    mark = Image.open(f'{root}/Resources/BrandMark.png').resize((34 * s, 34 * s), Image.LANCZOS)
    title = font(['InterDisplay-SemiBold.otf', 'Inter-SemiBold.otf', 'DejaVuSans-Bold.ttf'], 26 * s)
    small = font(['Inter-Medium.otf', 'Inter-Regular.otf', 'DejaVuSans.ttf'], 12 * s)
    tiny = font(['Inter-Regular.otf', 'DejaVuSans.ttf'], 11 * s)
    t = 'PhotoFlow'; tw = d.textlength(t, font=title)
    x0 = (W - (34 * s + 10 * s + tw)) / 2
    img.alpha_composite(mark, (int(x0), 34 * s))
    d.text((x0 + 44 * s, 36 * s), t, font=title, fill=(28, 30, 38, 255))
    # arrow: soft gradient line with chevron, between the two icon positions (170 / 490, y 205)
    ay = 205 * s
    for i in range(int(250 * s), int(410 * s)):
        k = (i - 250 * s) / (160 * s)
        col = (int(90 + 60 * k), int(150 - 40 * k), 255, int(110 + 120 * k))
        d.ellipse((i - 2 * s, ay - 2 * s, i + 2 * s, ay + 2 * s), fill=col)
    d.line([(398 * s, ay - 12 * s), (412 * s, ay), (398 * s, ay + 12 * s)], fill=(150, 110, 255, 235), width=4 * s, joint='curve')
    for txt, f, y, col in [('Drag PhotoFlow to Applications  ·  Ziehe PhotoFlow in den Programme-Ordner', small, 340, (60, 62, 72, 255)),
                           ('Intel & Apple Silicon  ·  100 % on-device', tiny, 362, (120, 122, 132, 255))]:
        w = d.textlength(txt, font=f); d.text(((W - w) / 2, y * s), txt, font=f, fill=col)
    return img.convert('RGB')

if __name__ == '__main__':
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), '..')
    render(1, root).save(f'{root}/Packaging/dmg-background.png', optimize=True)
    render(2, root).save(f'{root}/Packaging/dmg-background@2x.png', optimize=True)
    print('ok')
