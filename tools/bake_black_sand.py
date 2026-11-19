#!/usr/bin/env python3
"""Rebuild the black-sand albedo/height and normal/roughness maps.

Punalu'u-style basalt sand: charcoal with cool and warm patches, fine grain,
and scattered lighter grains. Alpha of the albedo map is height. Alpha of the
normal map is roughness. Deterministic; does not touch terrain height data.
"""

from pathlib import Path

import numpy as np
from PIL import Image

SIZE = 512
OUT = Path("/workspace/materials/surfaces")


def hash2(ix: np.ndarray, iy: np.ndarray, seed: int) -> np.ndarray:
    n = (ix.astype(np.uint32) * np.uint32(374761393)) ^ (
        iy.astype(np.uint32) * np.uint32(668265263)
    ) ^ np.uint32(seed * 1442695041)
    n = (n ^ (n >> np.uint32(13))) * np.uint32(1274126177)
    n = n ^ (n >> np.uint32(16))
    return (n & np.uint32(0xFFFFFF)).astype(np.float32) / np.float32(0xFFFFFF)


def value_noise(x: np.ndarray, y: np.ndarray, seed: int) -> np.ndarray:
    xi = np.floor(x).astype(np.int32)
    yi = np.floor(y).astype(np.int32)
    xf = x - xi
    yf = y - yi
    xf = xf * xf * (3.0 - 2.0 * xf)
    yf = yf * yf * (3.0 - 2.0 * yf)
    a = hash2(xi, yi, seed)
    b = hash2(xi + 1, yi, seed)
    c = hash2(xi, yi + 1, seed)
    d = hash2(xi + 1, yi + 1, seed)
    return a + (b - a) * xf + (c - a) * yf + (a - b - c + d) * xf * yf


def fbm(x: np.ndarray, y: np.ndarray, seed: int, octaves: int = 5) -> np.ndarray:
    value = np.zeros_like(x, dtype=np.float32)
    amp = 0.5
    freq = 1.0
    total = 0.0
    for i in range(octaves):
        value += amp * value_noise(x * freq, y * freq, seed + i * 19)
        total += amp
        amp *= 0.5
        freq *= 2.03
    return value / total


def main() -> None:
    yy, xx = np.mgrid[0:SIZE, 0:SIZE].astype(np.float32)
    u = xx / SIZE
    v = yy / SIZE

    macro = fbm(u * 3.0, v * 3.0, 4)
    meso = fbm(u * 9.0, v * 9.0, 11)
    grain = fbm(u * 48.0, v * 48.0, 21, octaves=3)
    fine = fbm(u * 140.0, v * 140.0, 33, octaves=2)
    pebbles = fbm(u * 22.0, v * 22.0, 51, octaves=4)

    # Near-black basalt, cool, with enough grain that a third-person camera can see it.
    deep = np.array([18.0, 20.0, 26.0], dtype=np.float32)
    mid = np.array([34.0, 37.0, 46.0], dtype=np.float32)
    lift = np.array([52.0, 56.0, 66.0], dtype=np.float32)
    rgb = deep + (mid - deep) * np.clip(macro * 1.2, 0.0, 1.0)[..., None]
    rgb = rgb + (lift - mid) * np.clip((meso[..., None] - 0.42) * 1.2, 0.0, 1.0)
    rgb *= 0.78 + 0.48 * grain[..., None]
    rgb += (fine[..., None] - 0.5) * np.array([14.0, 15.0, 18.0], dtype=np.float32)

    speck = np.clip((pebbles - 0.78) / 0.14, 0.0, 1.0)
    pebble_col = np.array([70.0, 74.0, 84.0], dtype=np.float32)
    rgb = rgb * (1.0 - speck[..., None] * 0.4) + pebble_col * speck[..., None] * 0.4
    rgb = np.clip(rgb, 8.0, 96.0)

    height = 0.42 + (grain - 0.5) * 0.10 + (fine - 0.5) * 0.05 + speck * 0.22
    height = np.clip(height, 0.12, 0.92)

    albedo = np.dstack([rgb, height * 255.0]).astype(np.uint8)
    Image.fromarray(albedo, mode="RGBA").save(OUT / "BlackSand_AH.png")

    # Standard tangent-space normal from the height field, plus roughness.
    strength = 4.2 + speck * 2.2
    dx = (np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)) * strength
    dy = (np.roll(height, -1, axis=0) - np.roll(height, 1, axis=0)) * strength
    nx = -dx
    ny = dy
    nz = np.ones_like(height)
    inv = 1.0 / np.sqrt(nx * nx + ny * ny + nz * nz)
    normal = np.dstack([(nx * inv * 0.5 + 0.5) * 255.0, (ny * inv * 0.5 + 0.5) * 255.0, (nz * inv * 0.5 + 0.5) * 255.0])
    # Dry sand stays matte. The shader drops roughness only where the swash wets it.
    rough = 228.0 - speck * 28.0 - (grain - 0.5) * 10.0
    rough = np.clip(rough, 190.0, 246.0)
    nrm = np.dstack([normal, rough]).astype(np.uint8)
    Image.fromarray(nrm, mode="RGBA").save(OUT / "BlackSand_NR.png")
    print("wrote black sand", albedo.shape, "rgb mean", rgb.mean(axis=(0, 1)), "rough mean", rough.mean())


if __name__ == "__main__":
    main()
