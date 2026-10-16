"""Generates the iNUTT app icon (1024x1024, no alpha) in the ScyHost night-sky style."""
import random, sys
from PIL import Image, ImageDraw, ImageFilter, ImageChops

S = 1024
out = sys.argv[1]
base = Image.new("RGB", (S, S), (13, 15, 20))

# gold haze top-right, violet haze bottom-left
glow = Image.new("RGB", (S, S), (0, 0, 0))
g = ImageDraw.Draw(glow)
g.ellipse((420, -260, 1300, 560), fill=(120, 96, 30))
g.ellipse((-380, 560, 520, 1400), fill=(60, 50, 120))
glow = glow.filter(ImageFilter.GaussianBlur(160))
img = ImageChops.add(base, glow)

d = ImageDraw.Draw(img)
random.seed(7)
for _ in range(60):
    x, y = random.randrange(S), random.randrange(S)
    r = random.choice([1, 1, 2, 2, 3])
    c = random.randrange(140, 255)
    d.ellipse((x - r, y - r, x + r, y + r), fill=(c, c, min(255, c + 20)))

# moon with radial shading
moon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
mcx, mcy, mr = 600, 400, 250
shade = Image.new("RGBA", (S, S))
sp = shade.load()
for y in range(mcy - mr, mcy + mr + 1):
    for x in range(mcx - mr, mcx + mr + 1):
        dx, dy = (x - (mcx - 90)) / (mr * 1.6), (y - (mcy - 90)) / (mr * 1.6)
        t = min(1.0, (dx * dx + dy * dy) ** 0.5)
        sp[x, y] = (int(255 - 40 * t), int(240 - 70 * t), int(180 - 110 * t), 255)
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).ellipse((mcx - mr, mcy - mr, mcx + mr, mcy + mr), fill=255)
halo = Image.new("RGB", (S, S), (0, 0, 0))
ImageDraw.Draw(halo).ellipse((mcx - mr - 60, mcy - mr - 60, mcx + mr + 60, mcy + mr + 60), fill=(110, 90, 30))
img = ImageChops.add(img, halo.filter(ImageFilter.GaussianBlur(60)))
img.paste(shade, (0, 0), mask)
d = ImageDraw.Draw(img)
for (cx, cy, r) in [(540, 320, 34), (680, 300, 22), (660, 470, 40), (520, 480, 18), (740, 400, 16)]:
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(222, 182, 92))
    d.ellipse((cx - r + 5, cy - r + 5, cx + r - 2, cy + r - 2), fill=(236, 200, 110))

# lavender cloud
cloud = Image.new("L", (S, S), 0)
c = ImageDraw.Draw(cloud)
c.rounded_rectangle((150, 600, 880, 820), radius=110, fill=255)
for (cx, cy, r) in [(330, 600, 140), (520, 540, 175), (700, 610, 130)]:
    c.ellipse((cx - r, cy - r, cx + r, cy + r), fill=255)
shadow = cloud.filter(ImageFilter.GaussianBlur(30))
img.paste((8, 8, 20), (0, 24), shadow)
grad = Image.new("RGB", (S, S))
gp = grad.load()
for y in range(S):
    t = max(0.0, min(1.0, (y - 380) / 460))
    col = (int(196 - 80 * t), int(187 - 90 * t), int(255 - 40 * t))
    for x in range(S):
        gp[x, y] = col
img.paste(grad, (0, 0), cloud)

# play glyph on the cloud
d = ImageDraw.Draw(img)
px, py, pr = 515, 690, 70
d.polygon([(px - pr * 0.55, py - pr * 0.8), (px - pr * 0.55, py + pr * 0.8), (px + pr * 0.85, py)], fill=(27, 21, 48))
img.save(out, "PNG")
