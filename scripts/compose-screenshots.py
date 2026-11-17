#!/usr/bin/env python3
"""Puts raw notch window captures (transparent PNGs from scripts/screenshots.sh) over the top
center of the desktop picture, as if taken on screen, for the README (docs/screenshots/*.png)
and the website (site/assets/*.jpg).

    python3 scripts/compose-screenshots.py <raw-dir>

<raw-dir> holds <name>.png for each shot, wallpaper.png (the desktop picture at the same scale)
and wallpaper-center.txt (the notch's center, in points from the picture's left edge).
Needs Pillow (pip install pillow).
"""
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent

# name: (canvas width, canvas height, publish to the site), in pixels at 2x
SHOTS = {
    "expanded": (1640, 740, True),
    "approval": (1640, 450, True),
    "question": (1640, 450, True),
    "finished": (1640, 320, True),
    "compact": (1640, 140, False),
}


def backdrop(raw_dir: Path, w: int, h: int) -> Image.Image:
    """The piece of desktop picture under the notch: centered on it, from the top of the screen."""
    try:
        wall = Image.open(raw_dir / "wallpaper.png").convert("RGB")
        center = int((raw_dir / "wallpaper-center.txt").read_text().split()[0]) * 2
    except (FileNotFoundError, ValueError, IndexError):
        print("no wallpaper.png: using a plain backdrop")
        return Image.new("RGB", (w, h), (12, 14, 22))
    left = min(max(center - w // 2, 0), max(wall.width - w, 0))
    return wall.crop((left, 0, left + w, h))


def compose(raw: Image.Image, back: Image.Image) -> Image.Image:
    w, h = back.size
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    layer.paste(raw.crop((0, 0, raw.width, min(raw.height, h))), ((w - raw.width) // 2, 0))
    return Image.alpha_composite(back.convert("RGBA"), layer).convert("RGB")


def main() -> None:
    raw_dir = Path(sys.argv[1] if len(sys.argv) > 1 else "raw")
    docs = ROOT / "docs" / "screenshots"
    site = ROOT / "site" / "assets"
    for name, (w, h, publish) in SHOTS.items():
        src = raw_dir / f"{name}.png"
        if not src.exists():
            print(f"skipped {name}: no {src}")
            continue
        img = compose(Image.open(src).convert("RGBA"), backdrop(raw_dir, w, h))
        img.save(docs / f"{name}.png", optimize=True)
        if publish:
            img.save(site / f"{name}.jpg", quality=86, optimize=True, progressive=True)
        print(f"composed {name} ({w}x{h})")


if __name__ == "__main__":
    main()
