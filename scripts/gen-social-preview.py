#!/usr/bin/env python3
"""Erzeugt das GitHub-Social-Preview-Bild (1280x640 PNG).

Reproduzierbar, damit sich das Bild nach einer Namens- oder Positionsänderung
neu erzeugen lässt statt von Hand nachgebaut zu werden.

Aufruf (braucht Pillow):
    python3 scripts/gen-social-preview.py [ziel.png]

GitHub zeigt Social-Previews in 1280x640; hochgeladen wird das Bild manuell
unter Settings → Social preview (dafür gibt es keine API).
"""
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

W, H = 1280, 640
ACCENT = (255, 138, 61)       # Orange aus dem App-Symbol
FG = (240, 241, 245)
MUTED = (156, 163, 175)
KEY_FG = (255, 196, 120)      # Tag-Schlüssel in der Beispielzeile
VALUE_FG = (140, 200, 255)    # Tag-Wert

ROOT = Path(__file__).resolve().parent.parent
ICON = ROOT / "docs" / "app-icon.png"
SUP = "/System/Library/Fonts/Supplemental/"


def font(name, size, index=0):
    return ImageFont.truetype(name, size, index=index)


def background():
    """Vertikaler Verlauf von dunkelgrau nach fast schwarz."""
    img = Image.new("RGB", (W, H))
    px = img.load()
    top, bottom = (38, 34, 40), (20, 21, 26)
    for y in range(H):
        t = y / H
        row = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for x in range(W):
            px[x, y] = row
    return img


def glow(img, center, radius, color, alpha):
    """Weicher Farbschimmer hinter dem Symbol — verbindet Symbol und Hintergrund."""
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    steps = 40
    for i in range(steps, 0, -1):
        r = radius * i / steps
        a = int(alpha * (1 - i / steps) ** 2)
        draw.ellipse(
            [center[0] - r, center[1] - r, center[0] + r, center[1] + r],
            fill=color + (a,),
        )
    return Image.alpha_composite(img.convert("RGBA"), layer)


def main():
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "docs" / "social-preview.png"

    img = background()
    img = glow(img, (1055, 250), 285, ACCENT, 70)

    # App-Symbol rechts
    if ICON.exists():
        icon = Image.open(ICON).convert("RGBA").resize((270, 270), Image.LANCZOS)
        img.paste(icon, (920, 115), icon)
    img = img.convert("RGB")

    d = ImageDraw.Draw(img)
    f_title = font(SUP + "Arial Bold.ttf", 104)
    f_sub = font(SUP + "Arial.ttf", 42)
    f_sub2 = font(SUP + "Arial.ttf", 33)
    f_mono = font("/System/Library/Fonts/Menlo.ttc", 34, index=1)
    f_small = font(SUP + "Arial.ttf", 28)

    d.text((90, 150), "Tag", font=f_title, fill=FG)
    w_tag = d.textlength("Tag ", font=f_title)
    d.text((90 + w_tag, 150), "Explosion", font=f_title, fill=ACCENT)

    d.text((94, 292), "Media metadata, edited on macOS", font=f_sub, fill=FG)
    d.text((94, 352), "audio tags  ·  EXIF/IPTC/XMP  ·  video  ·  e-books  ·  CLI",
           font=f_sub2, fill=MUTED)

    # Beispielzeile in einer dezenten Terminal-Box
    box_y = 436
    d.rounded_rectangle([90, box_y, 806, box_y + 76], radius=14,
                        fill=(28, 30, 37), outline=(62, 58, 66), width=2)
    parts = [("tagx set ", MUTED), ("song.mp3 ", FG),
             ("-t ", MUTED), ("ARTIST", KEY_FG), ("=", MUTED), ('"Miles Davis"', VALUE_FG)]
    x = 118
    for text, color in parts:
        d.text((x, box_y + 20), text, font=f_mono, fill=color)
        x += d.textlength(text, font=f_mono)

    # Das Alleinstellungsmerkmal gehört sichtbar aufs Bild.
    d.text((94, 542), "Every change goes through a checked copy — the previous version "
                      "lands in the trash.", font=f_small, fill=(126, 132, 145))

    # Bewusst ohne Versionsnummer: Das Bild soll einen Versions-Bump überleben.
    badge = "macOS 14+  ·  Swift 6  ·  MIT  ·  notarized"
    wb = d.textlength(badge, font=f_small)
    d.text((W - wb - 70, H - 48), badge, font=f_small, fill=MUTED)

    target.parent.mkdir(parents=True, exist_ok=True)
    img.save(target, "PNG")
    subprocess.run(["/usr/bin/sips", "-g", "pixelWidth", "-g", "pixelHeight", str(target)],
                   stdout=subprocess.DEVNULL, check=False)
    print("OK:", target)


if __name__ == "__main__":
    main()
