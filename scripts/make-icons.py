#!/usr/bin/env python3
"""Builds the icon set in icons/ and the app icon in Resources/ from icons/source/artwork.png.

    python3 -m venv /tmp/icons-venv && /tmp/icons-venv/bin/pip install numpy pillow scipy
    /tmp/icons-venv/bin/python scripts/make-icons.py

The artwork is the logo on one flat dark colour. It is cut out once (icons/source/logo.png); every variant is placed
and scaled from that cutout, and every size is resampled from the variant's 1024 px render. Resources/AppIcon.icns is
built from the macOS variant, and with Xcode's actool Resources/AppIcon.icon is compiled into Resources/Assets.car.
"""
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter
from scipy import ndimage

ROOT = Path(__file__).resolve().parent.parent
ICONS = ROOT / "icons"
RESOURCES = ROOT / "Resources"
NAME = "wallpaper-mage"
SIZES = [16, 24, 32, 48, 64, 96, 128, 180, 192, 256, 512, 1024]
MASTER = 1024
# Supersampling for the shape masks, so their edges are antialiased.
MASK_SS = 4


def cutout(artwork: Image.Image) -> tuple[Image.Image, tuple[int, int, int]]:
    """The logo with straight alpha, and the background colour it was cut from.

    An edge pixel C is a mix a*F + (1-a)*B of the logo colour F and the background B: F is the colour of the nearest
    solid logo pixel and a is the projection of C - B onto F - B. Edge pixels keep F (mixed with their own unmixed
    colour where they are mostly logo), so no dark fringe remains. Pixels darker than B (a faint shadow in the
    artwork) become transparent.
    """
    img = np.asarray(artwork.convert("RGB")).astype(np.float64)
    corners = np.concatenate([img[:40, :40], img[:40, -40:], img[-40:, :40], img[-40:, -40:]]).reshape(-1, 3)
    bg = np.median(corners, axis=0)
    diff = img - bg
    dist = np.linalg.norm(diff, axis=2)

    logo = dist > 24
    labels, count = ndimage.label(logo)
    sizes = ndimage.sum(logo, labels, range(1, count + 1))
    logo = np.isin(labels, 1 + np.flatnonzero(sizes >= 64))  # drop specks
    solid = ndimage.binary_erosion(logo, iterations=2)  # past the antialiased edge

    _, (iy, ix) = ndimage.distance_transform_edt(~solid, return_indices=True)
    nearest = img[iy, ix]
    fd = nearest - bg
    alpha = np.clip((diff * fd).sum(2) / np.maximum((fd * fd).sum(2), 1e-6), 0, 1)
    alpha[~ndimage.binary_dilation(logo, iterations=3)] = 0
    alpha[solid] = 1
    alpha[dist < 6] = 0

    with np.errstate(divide="ignore", invalid="ignore"):
        unmixed = np.nan_to_num(np.clip((img - (1 - alpha[..., None]) * bg) / alpha[..., None], 0, 255))
    weight = np.clip((alpha - 0.5) / 0.4, 0, 1)[..., None]
    rgb = np.where(solid[..., None], img, weight * unmixed + (1 - weight) * nearest)
    rgba = np.dstack([rgb, alpha * 255]).round().clip(0, 255).astype(np.uint8)
    rgba[alpha == 0, :3] = 0
    cut = Image.fromarray(rgba, "RGBA")
    return cut.crop(cut.getbbox()), tuple(int(round(c)) for c in bg)


def resample(img: Image.Image, size: int) -> Image.Image:
    """Lanczos on premultiplied alpha (no colour bleeding from transparent pixels), slightly sharpened when small."""
    out = img.convert("RGBa").resize((size, size), Image.LANCZOS).convert("RGBA")
    if size <= 64:
        out = out.filter(ImageFilter.UnsharpMask(radius=0.6, percent=60, threshold=0))
    return out


def place(logo: Image.Image, canvas: int, fraction: float, center=(0.5, 0.5)) -> Image.Image:
    """The logo scaled so its larger side is `fraction` of the canvas, centred on `center` (fractions)."""
    scale = fraction * canvas / max(logo.size)
    w, h = round(logo.width * scale), round(logo.height * scale)
    scaled = logo.convert("RGBa").resize((w, h), Image.LANCZOS).convert("RGBA")
    layer = Image.new("RGBA", (canvas, canvas))
    layer.paste(scaled, (round(center[0] * canvas - w / 2), round(center[1] * canvas - h / 2)))
    return layer


def superellipse(canvas: int, box: tuple[float, float, float, float], exponent: float) -> Image.Image:
    """An antialiased mask of the superellipse |x|^n + |y|^n = 1 inscribed in `box` (left, top, right, bottom)."""
    n = canvas * MASK_SS
    pixels = np.arange(n, dtype=np.float32) + 0.5
    l, t, r, b = (v * MASK_SS for v in box)
    x = np.abs((pixels - (l + r) / 2) / ((r - l) / 2)) ** exponent
    y = np.abs((pixels - (t + b) / 2) / ((b - t) / 2)) ** exponent
    inside = (y[:, None] + x[None, :]) <= 1
    return Image.fromarray(inside.astype(np.uint8) * 255, "L").resize((canvas, canvas), Image.BOX)


def tile(mask: Image.Image, color: tuple[int, int, int], logo_layer: Image.Image) -> Image.Image:
    """The background colour in the shape of `mask`, with the logo on top (clipped to the shape)."""
    base = Image.alpha_composite(Image.new("RGBA", mask.size, color + (255,)), logo_layer)
    base.putalpha(mask)
    return base


def with_shadow(icon: Image.Image, offset: int, blur: float, opacity: float) -> Image.Image:
    shadow = Image.new("RGBA", icon.size, (0, 0, 0, 0))
    a = icon.getchannel("A").point(lambda v: round(v * opacity))
    shadow.putalpha(a.filter(ImageFilter.GaussianBlur(blur)))
    shadow = shadow.transform(icon.size, Image.AFFINE, (1, 0, 0, 0, 1, -offset))
    return Image.alpha_composite(shadow, icon)


def silhouette(layer: Image.Image, color: tuple[int, int, int]) -> Image.Image:
    out = Image.new("RGBA", layer.size, color + (0,))
    out.putalpha(layer.getchannel("A"))
    return out


def variants(logo: Image.Image, bg: tuple[int, int, int]) -> dict[str, Image.Image]:
    """Every variant at MASTER px. The macOS one follows Apple's icon grid: an 824 px squircle in the 1024 canvas."""
    c = MASTER
    transparent = place(logo, c, 0.90)
    grid = (100, 100, 924, 924)
    return {
        "transparent": transparent,
        "square": tile(Image.new("L", (c, c), 255), bg, place(logo, c, 0.76)),
        "rounded": tile(superellipse(c, (0, 0, c, c), 5), bg, place(logo, c, 0.72)),
        "circle": tile(superellipse(c, (0, 0, c, c), 2), bg, place(logo, c, 0.70)),
        "macos": with_shadow(tile(superellipse(c, grid, 5), bg, place(logo, c, 0.58)),
                             offset=12, blur=14, opacity=0.35),
        "white": silhouette(transparent, (255, 255, 255)),
        "black": silhouette(transparent, (0, 0, 0)),
    }


def app_icon_document(logo: Image.Image, bg: tuple[int, int, int]) -> Path:
    """Resources/AppIcon.icon: an Icon Composer document (the system draws the shape, glass and shadow)."""
    doc = RESOURCES / "AppIcon.icon"
    if doc.exists():
        shutil.rmtree(doc)
    (doc / "Assets").mkdir(parents=True)
    place(logo, MASTER, 0.70).save(doc / "Assets" / "logo.png", optimize=True)
    color = "srgb:" + ",".join(f"{v / 255:.5f}" for v in bg) + ",1.00000"
    spec = {
        "fill": {"solid": color},
        "groups": [{
            "layers": [{"image-name": "logo.png", "name": "logo", "glass": False}],
            "shadow": {"kind": "neutral", "opacity": 0.5},
            "translucency": {"enabled": False, "value": 0.5},
        }],
        "supported-platforms": {"squares": "shared"},
    }
    # Icon Composer's own formatting, so saving the document there changes only what was edited.
    (doc / "icon.json").write_text(json.dumps(spec, indent=2, separators=(",", " : "), sort_keys=True) + "\n")
    return doc


def compile_app_icon(doc: Path) -> None:
    """Resources/Assets.car: the document compiled for macOS 26 (CFBundleIconName = AppIcon)."""
    if shutil.which("xcrun") is None or subprocess.run(["xcrun", "--find", "actool"], capture_output=True).returncode:
        print("actool not found (it comes with Xcode): Resources/Assets.car was not rebuilt")
        return
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["xcrun", "actool", str(doc), "--compile", tmp, "--platform", "macosx",
                        "--minimum-deployment-target", "26.0", "--app-icon", "AppIcon",
                        "--output-partial-info-plist", f"{tmp}/partial.plist", "--output-format", "human-readable-text",
                        "--errors", "--warnings"], check=True, stdout=subprocess.DEVNULL)
        shutil.copyfile(Path(tmp) / "Assets.car", RESOURCES / "Assets.car")


def icns() -> None:
    """Resources/AppIcon.icns (CFBundleIconFile), from the macOS variant. actool writes one too, but only up to
    256 px, so this one replaces it."""
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for points in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                suffix = "@2x" if scale == 2 else ""
                shutil.copyfile(ICONS / "macos" / f"{NAME}-macos-{points * scale}.png",
                                iconset / f"icon_{points}x{points}{suffix}.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(RESOURCES / "AppIcon.icns")], check=True)


def main() -> None:
    artwork = Image.open(ICONS / "source" / "artwork.png")
    logo, bg = cutout(artwork)
    logo.save(ICONS / "source" / "logo.png", optimize=True)
    for variant, image in variants(logo, bg).items():
        folder = ICONS / variant
        if folder.exists():
            shutil.rmtree(folder)
        folder.mkdir(parents=True)
        for size in SIZES:
            out = image if size == MASTER else resample(image, size)
            out.save(folder / f"{NAME}-{variant}-{size}.png", optimize=True)
    rounded = [Image.open(ICONS / "rounded" / f"{NAME}-rounded-{s}.png") for s in (16, 24, 32, 48, 64, 128, 256)]
    rounded[-1].save(ICONS / f"{NAME}.ico", sizes=[im.size for im in rounded], append_images=rounded[:-1])
    icns()
    compile_app_icon(app_icon_document(logo, bg))


if __name__ == "__main__":
    main()
