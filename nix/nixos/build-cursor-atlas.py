from __future__ import annotations

import json
import os
from re import A
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

from PIL import Image

CURSOR_NAMES = [
    "arrow",
    "up-arrow",
    "cross",
    "wait",
    "ibeam",
    "size_ver",
    "size_hor",
    "size_bdiag",
    "size_fdiag",
    "size_all",
    "blank",
    "split_v",
    "split_h",
    "pointing_hand",
    "forbidden",
    "whats_this",
    "progress",
    "openhand",
    "closedhand",
    "copy",
    "move",
    "link",
]

icon_theme = sys.argv[2]
cursors_dir = Path(sys.argv[1]) / "share" / "icons" / icon_theme / "cursors"
if not cursors_dir.is_dir():
    print(f"Cursor icon theme {icon_theme!r} doesn't exist")
    exit(1)

tdir = Path(tempfile.mkdtemp(prefix=f"initrd-cursor-atlas"))

cursor_sz = int(sys.argv[3])
print(f"Using cursor size {cursor_sz}x{cursor_sz}")


@dataclass
class CursorImage:
    size: int
    image: Image
    hotspot: list[int]


@dataclass
class Cursor:
    name: str
    images: dict[int, CursorImage]

    @staticmethod
    def convert(name: str) -> Cursor:
        xcursor = cursors_dir / name
        if not xcursor.is_file():
            print(f"Cursor {name!r} does not exist")
            xcursor = cursors_dir / "default"

        conf = tdir / f"{name}.conf"
        subprocess.check_call(
            ["xcur2png", "--quiet", "--conf", conf, "--directory", tdir, xcursor],
            stderr=subprocess.DEVNULL,
        )

        imgs = {}
        with conf.open("r") as f:
            for l in f:
                a = l.strip().split()
                if len(a) != 5:
                    continue

                sz, xhot, yhot, img, _ = a

                img = Image.open(img)
                assert img.width == img.height

                imgs[int(sz)] = CursorImage(img.width, img, [int(xhot), int(yhot)])

        return Cursor(name, imgs)


cursor_atlas = Image.new("RGBA", (cursor_sz, cursor_sz * len(CURSOR_NAMES)))
hotspots = []

for idx, name in enumerate(CURSOR_NAMES):
    if name == "blank":
        hotspots.append([0, 0])
        continue

    cursor = Cursor.convert(name)
    cursor_img = min(
        (img for img in cursor.images.values() if img.size >= cursor_sz),
        key=lambda img: img.size,
    )

    img = cursor_img.image.copy()
    img.resize((cursor_sz, cursor_sz), Image.Resampling.BILINEAR)
    cursor_atlas.paste(img, (0, cursor_sz * idx))

    hotspots.append(cursor_img.hotspot)

assert len(hotspots) == len(CURSOR_NAMES)

out = os.environ["out"]
os.mkdir(out)

cursor_atlas.save(f"{out}/atlas.png")

with open(f"{out}/config.json", "w") as f:
    json.dump(
        {
            "image": f"{out}/atlas.png",
            "cursorsPerRow": 1,
            "hotSpots": hotspots,
        },
        f,
    )

print(f"Wrote cursor atlas for icon theme {icon_theme!r} to {out}")
