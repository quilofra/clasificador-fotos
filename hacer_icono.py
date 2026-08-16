#!/usr/bin/env python3
"""Genera el icono de la app: una pila de fotos con las cuatro categorías."""
import os
import subprocess

from PIL import Image, ImageDraw

OUT = "build/icono.iconset"
os.makedirs(OUT, exist_ok=True)
S = 1024

TINTS = [(79, 141, 247), (229, 100, 92), (63, 178, 127), (138, 138, 142)]


def rounded(size, radius, fill):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(img).rounded_rectangle([0, 0, size - 1, size - 1],
                                          radius=radius, fill=fill)
    return img


canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# fondo con degradado vertical suave
bg = Image.new("RGBA", (S, S))
d = ImageDraw.Draw(bg)
for y in range(S):
    t = y / S
    d.line([(0, y), (S, y)], fill=(int(34 + 14 * t), int(36 + 16 * t), int(46 + 22 * t), 255))
mask = rounded(S, 225, (255, 255, 255, 255))
canvas.paste(bg, (0, 0), mask)

# pila de tres "fotos" ligeramente giradas
for i, (dx, dy, ang, alpha) in enumerate([(-60, 40, -9, 110), (0, 10, 4, 170), (60, -25, -2, 255)]):
    card = rounded(430, 40, (255, 255, 255, alpha))
    card = card.rotate(ang, resample=Image.BICUBIC, expand=True)
    canvas.alpha_composite(card, (S // 2 - card.width // 2 + dx, S // 2 - card.height // 2 + dy))

# cuatro puntos de color: las categorías
r = 42
gap = 46
total = 4 * 2 * r + 3 * gap
x = (S - total) // 2
y = S - 210
dr = ImageDraw.Draw(canvas)
for tint in TINTS:
    dr.ellipse([x, y, x + 2 * r, y + 2 * r], fill=tint + (255,))
    x += 2 * r + gap

for size in (16, 32, 64, 128, 256, 512, 1024):
    canvas.resize((size, size), Image.LANCZOS).save(f"{OUT}/icon_{size}x{size}.png")
    if size <= 512:
        canvas.resize((size * 2, size * 2), Image.LANCZOS).save(f"{OUT}/icon_{size}x{size}@2x.png")

subprocess.run(["iconutil", "-c", "icns", OUT, "-o", "build/Clasificador.icns"], check=True)
print("icono creado en build/Clasificador.icns")
