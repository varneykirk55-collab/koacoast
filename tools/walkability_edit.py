#!/usr/bin/env python3
"""Shape 2–3 eroded approach valleys and soften mid-slope steps.

Reads the height grid dumped by walkability_dump.gd. Writes an edited grid
and a route report. Does not touch Godot resources; walkability_apply.gd does.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

ROOT = Path("/agent/repos/koacoast")
HEIGHTS_IN = Path("/tmp/koacoast_heights.f32")
META_IN = Path("/tmp/koacoast_grid.txt")
HEIGHTS_OUT = Path("/tmp/koacoast_heights_edited.f32")
ROUTES_OUT = Path("/tmp/koacoast_routes.json")
PREVIEW_OUT = ROOT / "docs" / "walkability_before_after.png"

# Player floor_max_angle is 50°. Same bands as the slope tool.
GENTLE = 15.0
MODERATE = 35.0
WALK_LIMIT = 50.0
SPAWN = (48.0, 576.0)
CLIFF_POINTS = [
    (-20.0, 38.0),
    (76.0, -238.0),
    (-92.0, -584.0),
    (-216.0, -176.0),
    (494.0, -460.0),
    (-264.0, -636.0),
    (872.0, -70.0),
    (-436.0, -246.0),
]


def load_grid():
    meta = META_IN.read_text().split()
    w, d = int(meta[0]), int(meta[1])
    spacing = float(meta[2])
    min_loc = (int(meta[3]), int(meta[4]))
    rs = int(meta[7])
    raw = np.fromfile(HEIGHTS_IN, dtype=np.float32)
    if raw.size != w * d:
        raise SystemExit(f"height dump size {raw.size} != {w * d}")
    h = raw.reshape(d, w).astype(np.float64)
    origin = (min_loc[0] * rs * spacing, min_loc[1] * rs * spacing)
    return h, spacing, origin, rs, min_loc


def slope_deg(h: np.ndarray, spacing: float) -> np.ndarray:
    dhdx = np.empty_like(h)
    dhdz = np.empty_like(h)
    dhdx[:, 1:-1] = (h[:, 2:] - h[:, :-2]) / (2.0 * spacing)
    dhdx[:, 0] = (h[:, 1] - h[:, 0]) / spacing
    dhdx[:, -1] = (h[:, -1] - h[:, -2]) / spacing
    dhdz[1:-1, :] = (h[2:, :] - h[:-2, :]) / (2.0 * spacing)
    dhdz[0, :] = (h[1, :] - h[0, :]) / spacing
    dhdz[-1, :] = (h[-1, :] - h[-2, :]) / spacing
    return np.degrees(np.arctan(np.hypot(dhdx, dhdz)))


def world_of(z, x, origin, spacing):
    return origin[0] + float(x) * spacing, origin[1] + float(z) * spacing


def cell_of(xw, zw, origin, spacing, shape):
    x = int(round((xw - origin[0]) / spacing))
    z = int(round((zw - origin[1]) / spacing))
    z = int(np.clip(z, 0, shape[0] - 1))
    x = int(np.clip(x, 0, shape[1] - 1))
    return z, x


def stats(h, slope):
    land = h >= 0.0
    n = int(land.sum())
    if n == 0:
        return {}
    s = slope[land]
    return {
        "land_cells": n,
        "land_km2": n * 4.0 / 1e6,
        "gentle": 100.0 * np.mean(s < GENTLE),
        "moderate": 100.0 * np.mean((s >= GENTLE) & (s < MODERATE)),
        "steep": 100.0 * np.mean(s >= MODERATE),
        "over_limit": 100.0 * np.mean(s >= WALK_LIMIT),
        "min_h": float(h.min()),
        "max_h": float(h.max()),
    }


def smoothstep(u):
    u = np.clip(u, 0.0, 1.0)
    return u * u * (3.0 - 2.0 * u)


def flow_downstream(h, spacing):
    """D8 steepest descent. Returns flat index of downstream cell, or -1."""
    padded = np.pad(h, 1, mode="edge")
    best = np.zeros(h.shape, dtype=np.float64)
    down = np.full(h.shape, -1, dtype=np.int32)
    rows = np.arange(h.shape[0])[:, None]
    cols = np.arange(h.shape[1])[None, :]
    dirs = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]
    for dz, dx in dirs:
        shifted = padded[1 + dz : 1 + dz + h.shape[0], 1 + dx : 1 + dx + h.shape[1]]
        nz = np.clip(rows + dz, 0, h.shape[0] - 1)
        nx = np.clip(cols + dx, 0, h.shape[1] - 1)
        same = (nz == rows) & (nx == cols)
        dist = spacing * float(np.hypot(dz, dx))
        grade = np.where(same, -1.0, (h - shifted) / dist)
        neighbor = (nz * h.shape[1] + nx).astype(np.int32)
        take = grade > best
        best = np.where(take, grade, best)
        down = np.where(take, neighbor, down)
    return np.where(best > 0.02, down, -1)


def accumulate(h, down):
    order = np.argsort(h.ravel(), kind="mergesort")[::-1]
    acc = np.ones(h.size, dtype=np.float64)
    down_f = down.ravel()
    for idx in order:
        di = int(down_f[idx])
        if di >= 0:
            acc[di] += acc[idx]
    return acc.reshape(h.shape)


def trace_channel(h, acc, down, z, x, blocked, max_h=175.0):
    """Walk upstream along the dominant tributary."""
    height, width = h.shape
    path = [(z, x)]
    seen = {(z, x)}
    dirs = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]
    flat_here = z * width + x
    for _ in range(2500):
        best = None
        best_a = acc[z, x] * 0.08
        for dz, dx in dirs:
            nz, nx = z + dz, x + dx
            if nz < 0 or nx < 0 or nz >= height or nx >= width:
                continue
            if (nz, nx) in seen:
                continue
            if int(down[nz, nx]) != flat_here:
                continue
            if acc[nz, nx] > best_a:
                best_a = acc[nz, nx]
                best = (nz, nx)
        if best is None:
            break
        if blocked[best] or h[best] >= max_h:
            break
        z, x = best
        flat_here = z * width + x
        seen.add(best)
        path.append(best)
        if h[best] >= 165.0:
            break
    return path


def smooth_polyline(path, h, frozen, passes=2):
    if len(path) < 5:
        return path
    pts = np.array(path, dtype=np.float64)
    for _ in range(passes):
        nxt = pts.copy()
        nxt[1:-1] = pts[:-2] * 0.25 + pts[1:-1] * 0.5 + pts[2:] * 0.25
        for i in range(1, len(pts) - 1):
            z = int(np.clip(round(nxt[i, 0]), 0, h.shape[0] - 1))
            x = int(np.clip(round(nxt[i, 1]), 0, h.shape[1] - 1))
            if frozen[z, x]:
                nxt[i] = pts[i]
        pts = nxt
    out = []
    for zf, xf in pts:
        z = int(np.clip(round(zf), 0, h.shape[0] - 1))
        x = int(np.clip(round(xf), 0, h.shape[1] - 1))
        if not out or out[-1] != (z, x):
            out.append((z, x))
    return out


def noise_along(s, wavelength, seed, scale=1.0):
    rng = np.random.default_rng(seed)
    if s[-1] <= s[0]:
        return np.zeros_like(s)
    step = max(wavelength, 1.0)
    knots = np.arange(s[0] - step, s[-1] + 2 * step, step)
    vals = rng.normal(0.0, scale, size=knots.size)
    # Smooth the knots once so the grade wobble is gradual.
    if vals.size >= 5:
        vals = ndimage.uniform_filter1d(vals, size=3, mode="nearest")
    return np.interp(s, knots, vals)


def grade_limited(elev, s, seed):
    """Cut knickpoints so the climb mostly stays under ~22°, with benches and wobble."""
    n = elev.size
    grade = 13.0 + 5.0 * noise_along(s, 110.0, seed, 1.0)
    grade = np.clip(grade, 7.0, 20.0)
    # Occasional flatter benches, still not a constant grade.
    bench = noise_along(s, 160.0, seed + 17, 1.0) > 0.65
    grade = np.where(bench, np.minimum(grade, 7.0), grade)
    t = elev.copy()
    for i in range(1, n):
        ds = max(s[i] - s[i - 1], 0.5)
        max_up = np.tan(np.deg2rad(grade[i])) * ds
        if t[i] > t[i - 1] + max_up:
            t[i] = t[i - 1] + max_up
        max_down = np.tan(np.deg2rad(26.0)) * ds
        if t[i] < t[i - 1] - max_down:
            t[i] = min(t[i - 1] - max_down, elev[i] + 5.0)
    for i in range(n - 2, -1, -1):
        ds = max(s[i + 1] - s[i], 0.5)
        max_step = np.tan(np.deg2rad(24.0)) * ds
        if t[i] > t[i + 1] + max_step:
            t[i] = max(t[i + 1] + max_step, elev[i] - 24.0)
    t = np.minimum(t, elev + 5.0)
    t = np.maximum(t, elev - 34.0)
    # Keep the mouth pinned so the valley meets the untouched plain.
    t[0] = elev[0]
    if n > 2:
        t[1] = min(t[1], elev[0] + np.tan(np.deg2rad(18.0)) * max(s[1] - s[0], 0.5))
    wobble = 0.7 * noise_along(s, 28.0, seed + 3, 1.0)
    t = t + wobble
    t = np.minimum(t, elev + 5.0)
    t = np.maximum(t, elev - 34.0)
    t[0] = elev[0]
    # Re-clamp after the wobble so noise cannot recreate a wall.
    for i in range(1, n):
        ds = max(s[i] - s[i - 1], 0.5)
        cap = np.tan(np.deg2rad(26.0)) * ds
        if t[i] > t[i - 1] + cap:
            t[i] = t[i - 1] + cap
        if t[i] < t[i - 1] - cap:
            t[i] = t[i - 1] - cap
    return t


def carve_valley(h, editable, path, spacing, seed):
    if len(path) < 8:
        return
    pts = np.array(path, dtype=np.int32)
    elev = h[pts[:, 0], pts[:, 1]].copy()
    deltas = np.hypot(np.diff(pts[:, 0]), np.diff(pts[:, 1])) * spacing
    s = np.concatenate([[0.0], np.cumsum(deltas)])
    target = grade_limited(elev, s, seed)
    cut = np.maximum(0.0, elev - target)
    width_noise = noise_along(s, 90.0, seed + 9, 1.0)
    base = 30.0 + 20.0 * (0.5 + 0.5 * np.tanh(width_noise))
    # Wall slope near 28° so the cross-section stays yellow, not a slot.
    half_w = np.maximum(base, cut / np.tan(np.deg2rad(28.0)) + 12.0)
    half_w = np.clip(half_w, 26.0, 80.0)
    exponent = np.clip(1.15 + 0.45 * noise_along(s, 70.0, seed + 11, 1.0), 0.75, 1.9)
    height, width = h.shape
    base = h.copy()
    h_owner = np.full(h.shape, np.inf)
    for i, (z, x) in enumerate(path):
        rad = int(np.ceil(half_w[i] / spacing)) + 1
        z0, z1 = max(0, z - rad), min(height, z + rad + 1)
        x0, x1 = max(0, x - rad), min(width, x + rad + 1)
        zz, xx = np.ogrid[z0:z1, x0:x1]
        dist = np.hypot(zz - z, xx - x) * spacing
        inside = dist <= half_w[i]
        if not np.any(inside):
            continue
        u = np.clip(dist / half_w[i], 0.0, 1.0)
        blend = smoothstep(np.power(u, exponent[i]))
        floor = target[i]
        original = base[z0:z1, x0:x1]
        proposed = floor * (1.0 - blend) + original * blend
        proposed = np.minimum(proposed, original + 2.5)
        proposed = np.maximum(proposed, original - 36.0)
        edit = editable[z0:z1, x0:x1] & inside
        closer = edit & (dist < h_owner[z0:z1, x0:x1])
        h_owner[z0:z1, x0:x1] = np.where(closer, dist, h_owner[z0:z1, x0:x1])
        h[z0:z1, x0:x1] = np.where(closer, proposed, h[z0:z1, x0:x1])


def enforce_centerline(h, h0, path, editable, spacing):
    """Pin the walking line to a grade the 36 m cut budget can actually hold."""
    if len(path) < 4:
        return
    pts = np.array(path, dtype=np.int32)
    lo = h0[pts[:, 0], pts[:, 1]] - 36.0
    hi = h0[pts[:, 0], pts[:, 1]] + 2.5
    t = np.clip(h[pts[:, 0], pts[:, 1]].copy(), lo, hi)
    deltas = np.hypot(np.diff(pts[:, 0].astype(float)), np.diff(pts[:, 1].astype(float))) * spacing
    for i in range(1, len(t)):
        cap = np.tan(np.deg2rad(20.0)) * max(deltas[i - 1], spacing * 0.5)
        t[i] = min(t[i], t[i - 1] + cap)
        t[i] = max(t[i], t[i - 1] - cap)
        t[i] = min(max(t[i], lo[i]), hi[i])
    for i in range(len(t) - 2, -1, -1):
        cap = np.tan(np.deg2rad(22.0)) * max(deltas[i], spacing * 0.5)
        if t[i] > t[i + 1] + cap:
            t[i] = max(t[i + 1] + cap, lo[i])
    height, width = h.shape
    for i, (z, x) in enumerate(path):
        if not editable[z, x]:
            continue
        h[z, x] = t[i]
        for dz, dx in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)):
            nz, nx = z + dz, x + dx
            if nz < 0 or nx < 0 or nz >= height or nx >= width or not editable[nz, nx]:
                continue
            limit = t[i] + spacing * float(np.hypot(dz, dx)) * np.tan(np.deg2rad(30.0))
            if h[nz, nx] > limit:
                h[nz, nx] = max(limit, h0[nz, nx] - 36.0)


def dijkstra(cost, start, goal):
    """Lowest-cost path. cost is inf on blocked cells. goal is a boolean mask."""
    import heapq
    height, width = cost.shape
    dist = np.full(cost.shape, np.inf)
    prev = np.full(cost.size, -1, np.int32)
    dist[start] = 0.0
    pq = [(0.0, start[0] * width + start[1])]
    dirs = ((-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (-1, 1), (1, -1), (1, 1))
    found = None
    while pq:
        dcur, idx = heapq.heappop(pq)
        z, x = divmod(idx, width)
        if dcur > dist[z, x]:
            continue
        if goal[z, x] and dcur > 0.0:
            found = (z, x)
            break
        for dz, dx in dirs:
            nz, nx = z + dz, x + dx
            if nz < 0 or nx < 0 or nz >= height or nx >= width:
                continue
            step_cost = cost[nz, nx]
            if not np.isfinite(step_cost):
                continue
            nd = dcur + float(np.hypot(dz, dx)) * step_cost
            if nd < dist[nz, nx]:
                dist[nz, nx] = nd
                prev[nz * width + nx] = idx
                heapq.heappush(pq, (nd, nz * width + nx))
    if found is None:
        return []
    path = []
    cur = found[0] * width + found[1]
    while cur >= 0:
        z, x = divmod(cur, width)
        path.append((int(z), int(x)))
        cur = int(prev[cur])
    path.reverse()
    return path


def meander(path, h, hard, spacing, seed, amplitude=16.0, slope=None):
    """Push the centerline sideways so it wanders instead of cutting a straight ramp."""
    if len(path) < 8:
        return path
    pts = np.array(path, dtype=np.float64)
    tang = np.gradient(pts, axis=0)
    norm = np.hypot(tang[:, 0], tang[:, 1]) + 1e-6
    tang /= norm[:, None]
    perp = np.stack([-tang[:, 1], tang[:, 0]], axis=1)
    step = np.hypot(np.diff(pts[:, 0]), np.diff(pts[:, 1]))
    s = np.concatenate([[0.0], np.cumsum(step)]) * spacing
    off = amplitude * np.tanh(noise_along(s, 70.0, seed, 1.0))
    off += amplitude * 0.55 * np.tanh(noise_along(s, 160.0, seed + 5, 1.0))
    # Pin the mouth and the destination.
    if off.size > 4:
        off[:3] = 0.0
        off[-3:] = 0.0
    shifted = pts + perp * (off / spacing)[:, None]
    out = []
    for i, (zf, xf) in enumerate(shifted):
        z = int(np.clip(round(zf), 0, h.shape[0] - 1))
        x = int(np.clip(round(xf), 0, h.shape[1] - 1))
        steep = slope is not None and slope[z, x] > 32.0
        if hard[z, x] or h[z, x] < 22.0 or steep:
            z, x = path[i]
        if not out or out[-1] != (z, x):
            out.append((z, x))
    return out


def pick_routes(h, acc, down, slope, editable, hard, origin, spacing):
    land = h >= 0.0
    cz = np.average(np.nonzero(land)[0])
    cx = np.average(np.nonzero(land)[1])
    # Outlets: drainage mouths just inland of the frozen shore.
    outlets = (
        editable
        & (acc > 2500)
        & (h > 28.0)
        & (h < 58.0)
        & (slope < 22.0)
    )
    ys, xs = np.nonzero(outlets)
    if ys.size == 0:
        outlets = editable & (acc > 800) & (h > 26.0) & (h < 70.0) & (slope < 28.0)
        ys, xs = np.nonzero(outlets)
    cands = []
    for z, x in zip(ys.tolist(), xs.tolist()):
        ang = np.arctan2(z - cz, x - cx)
        cands.append((float(acc[z, x]), ang, z, x))
    cands.sort(reverse=True)
    # Thin to one mouth per neighborhood, then keep angular diversity.
    chosen_mouths = []
    for score, ang, z, x in cands:
        if any((z - mz) ** 2 + (x - mx) ** 2 < 80 ** 2 for _, _, mz, mx in chosen_mouths):
            continue
        if any(abs(np.arctan2(np.sin(ang - a), np.cos(ang - a))) < np.deg2rad(55) for a, _, _, _ in chosen_mouths):
            continue
        chosen_mouths.append((ang, score, z, x))
        if len(chosen_mouths) == 6:
            break
    routes = []
    for ang, score, z, x in chosen_mouths:
        blocked = hard | (h >= 190.0)
        path = trace_channel(h, acc, down, z, x, blocked)
        path = smooth_polyline(path, h, hard)
        if len(path) < 12:
            continue
        elev = h[tuple(np.array(path).T)]
        climb = float(elev.max() - elev[0])
        if climb < 55.0 or float(elev[-1]) < 95.0:
            continue
        length = 0.0
        pts = np.array(path)
        length = float(np.hypot(np.diff(pts[:, 0]), np.diff(pts[:, 1])).sum() * spacing)
        if length < 280.0:
            continue
        xw, zw = world_of(z, x, origin, spacing)
        routes.append({
            "ang": float(ang),
            "acc": float(score),
            "climb": climb,
            "length": length,
            "path": path,
            "mouth": (xw, zw),
        })
    routes.sort(key=lambda r: r["climb"] * np.sqrt(r["length"]), reverse=True)
    # Keep the best three that stay in different sectors.
    kept = []
    for route in routes:
        if any(abs(np.arctan2(np.sin(route["ang"] - k["ang"]), np.cos(route["ang"] - k["ang"]))) < np.deg2rad(50) for k in kept):
            continue
        kept.append(route)
        if len(kept) == 3:
            break
    return kept


def classify_names(routes):
    # Angle is atan2(z, x) in grid space, which matches world +z / +x.
    names = []
    for route in routes:
        deg = np.degrees(route["ang"])
        # Grid +z is world +z (north), +x is east.
        if -45 <= deg < 45:
            names.append("East approach")
        elif 45 <= deg < 135:
            names.append("North approach")
        elif deg >= 135 or deg < -135:
            names.append("West approach")
        else:
            names.append("South approach")
    # Disambiguate duplicates.
    seen = {}
    out = []
    for name in names:
        seen[name] = seen.get(name, 0) + 1
        out.append(name if seen[name] == 1 else f"{name} {seen[name]}")
    return out


def measure_route(h, slope, path, origin, spacing):
    pts = np.array(path, dtype=np.int32)
    elev = h[pts[:, 0], pts[:, 1]]
    surf = slope[pts[:, 0], pts[:, 1]]
    seg = np.hypot(np.diff(pts[:, 0].astype(float)), np.diff(pts[:, 1].astype(float))) * spacing
    length = float(seg.sum())
    dh = np.diff(elev)
    grade = np.degrees(np.arctan(np.abs(dh) / np.maximum(seg, 0.5)))
    x0, z0 = world_of(pts[0, 0], pts[0, 1], origin, spacing)
    x1, z1 = world_of(pts[-1, 0], pts[-1, 1], origin, spacing)
    return {
        "start": [round(x0, 1), round(z0, 1)],
        "end": [round(x1, 1), round(z1, 1)],
        "start_h": round(float(elev[0]), 1),
        "end_h": round(float(elev[-1]), 1),
        "length_m": round(length, 1),
        "mean_slope": round(float(surf.mean()), 2),
        "max_slope": round(float(surf.max()), 2),
        "pct_under_25": round(100.0 * float(np.mean(surf < 25.0)), 1),
        "pct_under_35": round(100.0 * float(np.mean(surf < 35.0)), 1),
        "mean_grade": round(float(grade.mean()), 2),
        "max_grade": round(float(grade.max()), 2),
    }


def colorize(h, slope):
    rgb = np.zeros(h.shape + (3,), dtype=np.uint8)
    water = h < 0.0
    t = np.clip((h - h.min()) / max(-h.min(), 1.0), 0, 1)
    rgb[water, 0] = (7 + t[water] * 24).astype(np.uint8)
    rgb[water, 1] = (18 + t[water] * 70).astype(np.uint8)
    rgb[water, 2] = (34 + t[water] * 80).astype(np.uint8)
    land = ~water
    s = slope
    gentle = land & (s < GENTLE)
    moderate = land & (s >= GENTLE) & (s < MODERATE)
    steep = land & (s >= MODERATE)
    rgb[gentle] = (61, 220, 140)
    rgb[moderate] = (245, 197, 66)
    rgb[steep] = (255, 77, 77)
    # Coastline.
    coast = land & ndimage.binary_dilation(water, iterations=1)
    rgb[coast] = (243, 230, 192)
    return rgb


def draw_routes(img, routes, origin, spacing, labels):
    draw = ImageDraw.Draw(img)
    colors = [(120, 220, 255), (255, 255, 255), (190, 160, 255)]
    for i, route in enumerate(routes):
        pts = []
        for z, x in route["path"]:
            # North up: image y = height - 1 - z, but this image is a raw array
            # with row 0 = south. We'll flip later. Store in array order.
            pts.append((x, z))
        if len(pts) > 1:
            draw.line(pts, fill=colors[i % 3], width=3)
        z, x = route["path"][0]
        draw.text((x + 6, z + 4), f"{i + 1} {labels[i]}", fill=colors[i % 3])


def main():
    h0, spacing, origin, _rs, _min_loc = load_grid()
    slope0 = slope_deg(h0, spacing)
    before = stats(h0, slope0)
    print("BEFORE", json.dumps(before))

    water = h0 < 0.5
    dist_water = ndimage.distance_transform_edt(~water) * spacing
    slope = slope0
    coast = h0 < 24.0
    # Major sea cliffs only: steep ground close to the water, not every inland step.
    sea_cliff = (dist_water < 55.0) & (slope > 48.0) & (h0 < 160.0) & (h0 >= 0.0)
    sea_cliff = ndimage.binary_dilation(sea_cliff, iterations=3)
    # 80° faces, plus a pad around each recorded cliff-group summit.
    cliff_face = ndimage.binary_dilation(slope >= 78.0, iterations=4)
    zz, xx = np.ogrid[: h0.shape[0], : h0.shape[1]]
    for xw, zw in CLIFF_POINTS:
        czc, cxc = cell_of(xw, zw, origin, spacing, h0.shape)
        cliff_face |= (zz - czc) ** 2 + (xx - cxc) ** 2 <= (18.0 / spacing) ** 2
    peak = h0 >= 230.0
    # High ridgeline crests. Mid-slope steps below this stay editable.
    upper_face = (h0 >= 200.0) & (slope >= 62.0)
    iz, ix = cell_of(SPAWN[0], SPAWN[1], origin, spacing, h0.shape)
    spawn = (zz - iz) ** 2 + (xx - ix) ** 2 <= (24.0 / spacing) ** 2
    shore_band = dist_water <= 16.0
    hard = coast | sea_cliff | cliff_face | peak | upper_face | spawn | shore_band

    # Cliff control points must sit inside the hard mask.
    for xw, zw in CLIFF_POINTS:
        z, x = cell_of(xw, zw, origin, spacing, h0.shape)
        print(
            f"CLIFF ({xw:.0f},{zw:.0f}) h={h0[z, x]:.1f} slope={slope0[z, x]:.1f} "
            f"hard={bool(hard[z, x])} dist_water={dist_water[z, x]:.0f}"
        )

    editable = (~hard) & (h0 >= 26.0) & (h0 < 205.0) & (dist_water > 36.0)
    dist_hard = ndimage.distance_transform_edt(~hard)
    fade = np.clip((dist_hard - 2.0) / 8.0, 0.0, 1.0)
    fade *= np.clip((dist_water - 40.0) / 24.0, 0.0, 1.0)
    fade *= np.clip((h0 - 28.0) / 12.0, 0.0, 1.0)

    # The steep mid-slopes are mostly stair-steps: the 60 m hillside is already
    # under 35°. Blend toward that broader shape, capped so peaks and cliffs
    # are not undercut into a new wall.
    weight = ((~hard) & (h0 >= 0.0)).astype(np.float64)
    smooth = ndimage.gaussian_filter(h0 * weight, sigma=32.0) / np.maximum(
        ndimage.gaussian_filter(weight, sigma=32.0), 1e-4
    )
    # Wider fade so a lowered hillside does not leave a quarry face against a frozen cliff.
    fade = np.clip((dist_hard - 3.0) / 16.0, 0.0, 1.0)
    fade *= np.clip((dist_water - 48.0) / 36.0, 0.0, 1.0)
    fade *= np.clip((h0 - 30.0) / 16.0, 0.0, 1.0)
    alpha = 0.86 * fade * editable.astype(np.float64)
    delta = np.clip(smooth - h0, -18.0, 8.0)
    h = np.where(hard, h0, h0 + delta * alpha)

    slope_mid = slope_deg(h, spacing)
    land_c = np.nonzero(h0 >= 0.0)
    cz = float(np.mean(land_c[0]))
    cx = float(np.mean(land_c[1]))
    # Travel cost prefers the existing gentle ground and refuses cliff faces.
    travel = np.full(h.shape, np.inf)
    open_ground = (~hard) & (h > 24.0) & (h < 210.0) & (slope_mid < 64.0)
    travel[open_ground] = 1.0 + 9.0 * np.clip((slope_mid[open_ground] - 8.0) / 14.0, 0.0, 6.0)
    low = ndimage.gaussian_filter(h, sigma=14.0)
    # Prefer hollows over spur crests so the line reads as a valley.
    travel[open_ground & (h > low + 4.0)] *= 2.2
    travel[open_ground & (h < low - 2.0)] *= 0.72
    dist_c = np.hypot(zz - cz, xx - cx) * spacing
    goal = (~hard) & (h > 130.0) & (h < 190.0) & (slope_mid < 28.0) & (dist_c < 320.0)
    if int(goal.sum()) < 200:
        goal = (~hard) & (h > 115.0) & (h < 200.0) & (slope_mid < 34.0) & (dist_c < 420.0)
    print("GOAL_CELLS", int(goal.sum()), "OPEN", int(open_ground.sum()))

    plain = editable & (h0 > 30.0) & (h0 < 52.0) & (slope0 < 14.0) & (dist_water > 70.0)
    gys, gxs = np.nonzero(goal)
    # Farthest-point sample so the three valleys reach different parts of the interior.
    chosen_goals = []
    if gys.size:
        seed_i = int(np.argmin((gys - cz) ** 2 + (gxs - cx) ** 2))
        chosen_goals.append((int(gys[seed_i]), int(gxs[seed_i])))
        pool = np.column_stack([gys, gxs])[::8]
        while len(chosen_goals) < 3 and pool.size:
            best_i = None
            best_d = -1.0
            for i, (gz, gx) in enumerate(pool):
                dmin = min((gz - czg) ** 2 + (gx - cxg) ** 2 for czg, cxg in chosen_goals)
                if dmin > best_d:
                    best_d = dmin
                    best_i = i
            if best_d < (140.0 / spacing) ** 2:
                break
            chosen_goals.append((int(pool[best_i, 0]), int(pool[best_i, 1])))
    print("GOALS", [world_of(z, x, origin, spacing) for z, x in chosen_goals])

    routes = []
    for gi, (gz, gx) in enumerate(chosen_goals):
        goal_disk = (zz - gz) ** 2 + (xx - gx) ** 2 <= (50.0 / spacing) ** 2
        goal_disk &= (~hard) & (h > 110.0) & (slope_mid < 42.0)
        if int(goal_disk.sum()) < 5:
            print("NO_GOAL_DISK", world_of(gz, gx, origin, spacing))
            continue
        dist_g = np.hypot(zz - gz, xx - gx) * spacing
        band = plain & (dist_g > 260.0) & (dist_g < 720.0)
        for r in routes:
            rz, rx = r["path"][0]
            band &= (zz - rz) ** 2 + (xx - rx) ** 2 > 90 ** 2
        if int(band.sum()) < 8:
            band = plain & (dist_g > 200.0)
        if int(band.sum()) < 8:
            print("NO_MOUTH", world_of(gz, gx, origin, spacing))
            continue
        score = np.abs(dist_g - 420.0) + slope0 * 12.0
        score = np.where(band, score, 1e18)
        accepted = False
        for _try in range(6):
            if not np.isfinite(score).any() or score.min() > 1e17:
                break
            sz, sx = np.unravel_index(int(np.argmin(score)), h.shape)
            score[max(0, sz - 8) : sz + 9, max(0, sx - 8) : sx + 9] = 1e18
            path = dijkstra(travel, (int(sz), int(sx)), goal_disk)
            if len(path) < 20:
                continue
            path = smooth_polyline(path, h, hard, passes=2)
            path = meander(path, h, hard, spacing, seed=80 + gi * 19 + _try, amplitude=8.0, slope=slope_mid)
            path = smooth_polyline(path, h, hard, passes=1)
            psl = np.array([slope_mid[pz, px] for pz, px in path])
            elev = np.array([h[pz, px] for pz, px in path])
            climb = float(elev[-1] - elev[0])
            pts = np.array(path, dtype=float)
            length = float(np.hypot(np.diff(pts[:, 0]), np.diff(pts[:, 1])).sum() * spacing)
            # Only keep a line that is already mostly moderate, so the valley
            # cut is cleaning a corridor rather than trenching a cliff.
            if climb < 45.0 or length < 200.0 or float(np.percentile(psl, 90)) > 40.0 or float(psl.max()) > 55.0:
                continue
            routes.append({
                "ang": float(np.arctan2(gz - cz, gx - cx)),
                "path": path,
                "mouth": world_of(int(sz), int(sx), origin, spacing),
                "climb": climb,
                "length": length,
                "acc": 0.0,
            })
            accepted = True
            break
        if not accepted:
            print("NO_GENTLE_PATH", world_of(gz, gx, origin, spacing))
    # Fill any missing compass sector from the coastal plain, so the big
    # northwest lowland gets its own valley if the central goal was too steep.
    have = [r["ang"] for r in routes]
    for sector in (110.0, 170.0, -100.0, 40.0):
        if len(routes) >= 3:
            break
        sang = np.deg2rad(sector)
        if any(abs(np.arctan2(np.sin(sang - a), np.cos(sang - a))) < np.deg2rad(45) for a in have):
            continue
        sector_goal = goal & (np.arctan2(zz - cz, xx - cx) > sang - 0.45) & (np.arctan2(zz - cz, xx - cx) < sang + 0.45)
        if int(sector_goal.sum()) < 20:
            sector_goal = (~hard) & (h > 115.0) & (h < 180.0) & (slope_mid < 34.0) & (dist_c < 450.0)
            sector_goal &= np.abs(np.arctan2(np.sin(np.arctan2(zz - cz, xx - cx) - sang), np.cos(np.arctan2(zz - cz, xx - cx) - sang))) < 0.5
        if int(sector_goal.sum()) < 10:
            continue
        gys, gxs = np.nonzero(sector_goal)
        mid = int(len(gys) / 2)
        chosen_goals.append((int(gys[mid]), int(gxs[mid])))
        gz, gx = chosen_goals[-1]
        goal_disk = (zz - gz) ** 2 + (xx - gx) ** 2 <= (60.0 / spacing) ** 2
        goal_disk &= (~hard) & (h > 105.0)
        dist_g = np.hypot(zz - gz, xx - gx) * spacing
        band = plain & (dist_g > 240.0) & (dist_g < 800.0)
        if int(band.sum()) < 8:
            continue
        score = np.abs(dist_g - 400.0) + slope0 * 8.0
        score = np.where(band, score, 1e18)
        placed = False
        for _try in range(5):
            if score.min() > 1e17:
                break
            sz, sx = np.unravel_index(int(np.argmin(score)), h.shape)
            score[max(0, sz - 10) : sz + 11, max(0, sx - 10) : sx + 11] = 1e18
            path = dijkstra(travel, (int(sz), int(sx)), goal_disk)
            if len(path) < 20:
                continue
            path = smooth_polyline(path, h, hard, passes=2)
            psl = np.array([slope_mid[pz, px] for pz, px in path])
            elev = np.array([h[pz, px] for pz, px in path])
            climb = float(elev[-1] - elev[0])
            length = float(np.hypot(np.diff(np.array(path, float)[:, 0]), np.diff(np.array(path, float)[:, 1])).sum() * spacing)
            if climb < 40.0 or length < 180.0 or float(np.percentile(psl, 90)) > 36.0 or float(psl.max()) > 46.0:
                continue
            routes.append({
                "ang": float(sang),
                "path": path,
                "mouth": world_of(int(sz), int(sx), origin, spacing),
                "climb": climb,
                "length": length,
                "acc": 0.0,
            })
            have.append(float(sang))
            placed = True
            break
        if not placed:
            print("SECTOR_SKIP", sector)
    print(f"ROUTES_FOUND {len(routes)}")
    for i, route in enumerate(routes):
        carve_valley(h, ~hard, route["path"], spacing, seed=100 + i * 17)

    # Erosion is capped. Tiny fills (already <= 2.5 m) stay. Hard cells are exact.
    h = np.maximum(h, h0 - 36.0)
    h = np.minimum(h, h0 + 2.5)
    h = np.where(h0 >= 0.0, np.maximum(h, 0.2), h)
    h = np.where(hard, h0, h)
    for route in routes:
        enforce_centerline(h, h0, route["path"], ~hard, spacing)
    h = np.where(hard, h0, h)
    assert np.isfinite(h).all()

    slope1 = slope_deg(h, spacing)
    after = stats(h, slope1)
    print("AFTER", json.dumps(after))
    print(
        "PEAK",
        float(h0.max()),
        float(h.max()),
        "FROZEN_MAX_ABS",
        float(np.max(np.abs(h - h0)[hard])),
        "EDITED_CELLS",
        int(np.sum(np.abs(h - h0) > 0.02)),
    )

    labels = classify_names(routes)
    measured = []
    for i, route in enumerate(routes):
        info = measure_route(h, slope1, route["path"], origin, spacing)
        info["name"] = labels[i]
        info["path_px"] = route["path"]
        measured.append(info)
        print("ROUTE", json.dumps({k: v for k, v in info.items() if k != "path_px"}))

    # Side-by-side, north up.
    before_rgb = np.flipud(colorize(h0, slope0))
    after_rgb = np.flipud(colorize(h, slope1))
    for route, label, color in zip(routes, labels, [(80, 230, 255), (255, 255, 255), (200, 170, 255)]):
        pts = []
        H = h.shape[0]
        for z, x in route["path"]:
            pts.append((int(x), int(H - 1 - z)))
        layer = Image.fromarray(after_rgb, mode="RGB")
        draw = ImageDraw.Draw(layer)
        if len(pts) > 1:
            draw.line(pts, fill=color, width=3)
        draw.text((pts[0][0] + 4, pts[0][1] + 4), label, fill=color)
        after_rgb = np.array(layer)
        layer_b = Image.fromarray(before_rgb, mode="RGB")
        draw_b = ImageDraw.Draw(layer_b)
        if len(pts) > 1:
            draw_b.line(pts, fill=color, width=2)
        draw_b.text((pts[0][0] + 4, pts[0][1] + 4), label, fill=color)
        before_rgb = np.array(layer_b)

    pad = 16
    header = 36
    canvas = Image.new("RGB", (before_rgb.shape[1] * 2 + pad * 3, before_rgb.shape[0] + header + pad), (8, 14, 22))
    draw = ImageDraw.Draw(canvas)
    draw.text((pad, 10), "BEFORE  slope  green <15   yellow 15-35   red 35+", fill=(180, 220, 230))
    draw.text((pad * 2 + before_rgb.shape[1], 10), "AFTER  valleys labeled", fill=(180, 220, 230))
    canvas.paste(Image.fromarray(before_rgb, mode="RGB"), (pad, header))
    canvas.paste(Image.fromarray(after_rgb, mode="RGB"), (pad * 2 + before_rgb.shape[1], header))
    PREVIEW_OUT.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(PREVIEW_OUT)
    print("PREVIEW", PREVIEW_OUT)

    serial_routes = []
    for info in measured:
        item = {k: v for k, v in info.items() if k != "path_px"}
        item["path"] = [[int(z), int(x)] for z, x in info["path_px"]]
        serial_routes.append(item)
    ROUTES_OUT.write_text(json.dumps({
        "origin": origin,
        "spacing": spacing,
        "shape": list(h.shape),
        "before": before,
        "after": after,
        "routes": serial_routes,
    }))
    h.astype(np.float32).tofile(HEIGHTS_OUT)
    print("WROTE", HEIGHTS_OUT)


if __name__ == "__main__":
    main()
