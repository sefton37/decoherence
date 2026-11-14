#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Spec 577 S2a post-processing for the scenic render tool.

Two modes, both read-only with respect to the game frames:

  post.py finish OUT_DIR   reads OUT_DIR/raw.json (written by scenic_shots.gd) and the saved shot PNGs,
                           measures the pixel statistics, judges every shot against thresholds.json, writes
                           the 1600 and 800 px WebP copies, the contact sheet and manifest.json.
  post.py richness OUT_DIR reads OUT_DIR/raw.json (written by richness_probe.gd), measures the pixel richness of
                           the three bench frames, judges the bars in richness_bars.json and writes
                           OUT_DIR/richness.json (Spec 580). Exits 1 when any bar fails.
  post.py compare A B      A and B are render directories or single image files. Prints one line:
                           SCENIC_DET manifest_equal=<0|1|na> rms=<float>
                           (manifest_equal ignores generated_epoch; rms is RMS of 0..255 over RGB).

The PNG the engine saved is never modified: the WebP files are re-encodes of it and the contact sheet is a
labelled montage of those frames.
"""
import glob
import json
import os
import subprocess
import sys
import time

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

# Contact sheet geometry: 3 columns x 4 rows of 640x360 cells.
CELL_W, CELL_H, GUTTER, LABEL_H, COLS = 640, 360, 8, 26, 3


def load_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def shots_path():
    return os.environ.get("SCENIC_SHOTS") or os.path.join(HERE, "shots.json")


# ---------------------------------------------------------------- pixel statistics
def pixel_stats(png_path):
    """luma_range (p95 - p5 of luma, of 255), warm_cool, black_frac, white_frac for one frame."""
    px = np.asarray(Image.open(png_path).convert("RGB"), dtype=np.float64).reshape(-1, 3)
    r, g, b = px[:, 0], px[:, 1], px[:, 2]
    luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
    p5, p10, p90, p95 = np.percentile(luma, [5, 10, 90, 95])
    bright = luma >= p90
    dark = luma <= p10
    warm_cool = float((r[bright] - b[bright]).mean() - (r[dark] - b[dark]).mean())
    black = float(np.mean(px.max(axis=1) <= 10))
    white = float(np.mean(px.min(axis=1) >= 245))
    return {
        "luma_range": round(float(p95 - p5), 1),
        "warm_cool": round(warm_cool, 1),
        "black_frac": round(black, 4),
        "white_frac": round(white, 4),
    }


def judge(rec, st, thr, authored_xz):
    """Returns the list of floors a shot fails; empty means it passes."""
    fails = []
    if st["luma_range"] < thr["luma_range_min"]:
        fails.append("luma_range")
    if st["warm_cool"] < thr["warm_cool_min"]:
        fails.append("warm_cool")
    if st["black_frac"] > thr["black_frac_max"]:
        fails.append("black_frac")
    if st["white_frac"] > thr["white_frac_max"]:
        fails.append("white_frac")
    hy = rec.get("horizon_y_frac")
    if hy is not None and abs(hy - 0.5) < thr["horizon_center_exclusion"]:
        fails.append("horizon_centred")
    if rec["subject"] == "horizon" and hy is None:
        fails.append("horizon_not_in_frame")
    if rec["subject"] == "water" and rec["water_frac"] < thr["water_subject_min_frac"]:
        fails.append("water_frac")
    if rec["clearance_m"] < thr["clearance_min_m"]:
        fails.append("clearance")
    if rec.get("homestead_in_frame"):
        fails.append("homestead_in_frame")
    here = authored_xz.get(rec["id"])
    if here is not None:
        others = [v for k, v in authored_xz.items() if k != rec["id"]]
        if others and min(((here[0] - o[0]) ** 2 + (here[1] - o[1]) ** 2) ** 0.5 for o in others) < thr["min_pairwise_xz_m"]:
            fails.append("pairwise_spread")
    return fails


def judge_richness(rec, rs, thr):
    """Spec 580: the names of the richness floors a shot misses (far ground, far trees, sky share, detail, hue
    bins, species in frame); empty means it is rich enough. The bars are floors, never a way to pick a picture."""
    fails = []
    if rec["far_ground_p90_m"] < thr["far_ground_p90_min_m"]:
        fails.append("far_ground_p90")
    if rec["tree_far_p95_m"] < thr["tree_far_p95_min_m"]:
        fails.append("tree_far_p95")
    if rs["sky_frac"] > thr["sky_frac_max"]:
        fails.append("sky_frac")
    if rs["detail"] < thr["detail_min"]:
        fails.append("detail")
    if rs["hue_bins"] < thr["hue_bins_min"]:
        fails.append("hue_bins")
    if rec["species_ge10"] < thr["species_ge10_min"]:
        fails.append("species_ge10")
    return fails


# ---------------------------------------------------------------- contact sheet
def load_font(size):
    for p in ("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/usr/share/fonts/truetype/lato/Lato-Medium.ttf"):
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def contact_sheet(out_dir, cands):
    """cands: manifest shot records (non-control), in shots.json order. Returns the sheet width."""
    rows = (len(cands) + COLS - 1) // COLS
    w = COLS * CELL_W + (COLS + 1) * GUTTER
    h = rows * (CELL_H + LABEL_H) + (rows + 1) * GUTTER
    sheet = Image.new("RGB", (w, h), (24, 24, 24))
    d = ImageDraw.Draw(sheet)
    font = load_font(15)
    for i, s in enumerate(cands):
        x = GUTTER + (i % COLS) * (CELL_W + GUTTER)
        y = GUTTER + (i // COLS) * (CELL_H + LABEL_H + GUTTER)
        im = Image.open(os.path.join(out_dir, "shot-%s.png" % s["id"])).convert("RGB").resize((CELL_W, CELL_H), Image.LANCZOS)
        sheet.paste(im, (x, y))
        tag = "PASS" if s["pass"] else "fail"
        river = "river" if s["river_bank_in_frame"] else "no-river"
        label = "%s | %s | fov %g | sun %g | %s | %s" % (s["id"], s["view_distance"], s["fov_deg"], s["sun_elevation_deg"], river, tag)
        d.text((x + 2, y + CELL_H + 4), label, fill=(235, 235, 235), font=font)
    sheet.save(os.path.join(out_dir, "contact.png"), "PNG")
    return w


# ---------------------------------------------------------------- richness statistics (Spec 580)
BLOCK = 8
FLAT_STD = 1.5  # an 8x8 block whose luma std is under this is flat (gradient sky, a bare wall)
DETAIL_STD = 6.0  # an 8x8 block whose luma std is at least this carries detail
HUE_BIN_DEG = 20
HUE_BIN_SHARE = 0.01  # a hue bin is occupied when it holds this share of the non-flat pixels
HUE_MIN_SAT = 0.15  # only pixels at least this saturated have a hue worth counting


def richness_stats(png_path):
    """sky_frac, detail, hue_bins and sat_mean of one frame (the definitions are in the spec's contract).

    sky_frac  share of 8x8 blocks that are flat; detail  share of 8x8 blocks with luma std >= DETAIL_STD;
    hue_bins  of 18 bins of 20 degrees, how many hold >= 1 percent of the non-flat pixels (saturation >= 0.15);
    sat_mean  mean HSV saturation over the non-flat pixels."""
    px = np.asarray(Image.open(png_path).convert("RGB"), dtype=np.float64)
    h, w = px.shape[0] // BLOCK * BLOCK, px.shape[1] // BLOCK * BLOCK
    px = px[:h, :w]
    luma = 0.2126 * px[..., 0] + 0.7152 * px[..., 1] + 0.0722 * px[..., 2]
    blocks = luma.reshape(h // BLOCK, BLOCK, w // BLOCK, BLOCK).transpose(0, 2, 1, 3).reshape(-1, BLOCK * BLOCK)
    std = blocks.std(axis=1)
    flat = std < FLAT_STD
    sky_frac = float(flat.mean())
    detail = float((std >= DETAIL_STD).mean())
    nonflat_pix = np.repeat(~flat, BLOCK * BLOCK).reshape(h // BLOCK, w // BLOCK, BLOCK, BLOCK).transpose(0, 2, 1, 3).reshape(h, w)
    rgb = px[nonflat_pix]
    if rgb.shape[0] == 0:
        return {"sky_frac": round(sky_frac, 4), "detail": round(detail, 4), "hue_bins": 0, "sat_mean": 0.0}
    mx, mn = rgb.max(axis=1), rgb.min(axis=1)
    delta = mx - mn
    sat = np.where(mx > 0, delta / np.maximum(mx, 1e-9), 0.0)
    r, g, b = rgb[:, 0], rgb[:, 1], rgb[:, 2]
    hue = np.zeros(rgb.shape[0])
    d = np.maximum(delta, 1e-9)
    hue = np.where(mx == r, ((g - b) / d) % 6.0, hue)
    hue = np.where((mx == g) & (mx != r), (b - r) / d + 2.0, hue)
    hue = np.where((mx == b) & (mx != r) & (mx != g), (r - g) / d + 4.0, hue)
    hue_deg = (hue * 60.0) % 360.0
    chroma = sat >= HUE_MIN_SAT
    bins = np.bincount((hue_deg[chroma] // HUE_BIN_DEG).astype(int), minlength=360 // HUE_BIN_DEG)
    occupied = int((bins >= HUE_BIN_SHARE * rgb.shape[0]).sum())
    return {"sky_frac": round(sky_frac, 4), "detail": round(detail, 4), "hue_bins": occupied, "sat_mean": round(float(sat.mean()), 4)}


SKY_TOL = 4  # a pixel within this (max channel) of the sky-only frame is sky
WATER_TOL = 8  # a pixel that changes by more than this when the water is hidden is water
FLOAT_NEAR_ROWS = 4  # a water pixel is floating when the pixels this many and this many more rows below are sky
FLOAT_FAR_ROWS = 9


def edge_stats(rec):
    """Spec 580 S4 edge measurements of one edge pose from its three frames (normal, water hidden, world hidden).

    below_horizon_sky_frac  share of the frame, below the horizon line, that still shows pure sky: the gap where
                            ground should be (a world that ends in a cliff of sky)
    floating_water_px       water pixels with sky both a little and a little further below them: the signature of
                            a water strip hanging in the sky with nothing under it
    water_px                all water pixels (the control that the metric sees water at all)"""
    img = np.asarray(Image.open(rec["png"]).convert("RGB"), dtype=np.int16)
    nowater = np.asarray(Image.open(rec["nowater_png"]).convert("RGB"), dtype=np.int16)
    sky = np.asarray(Image.open(rec["sky_png"]).convert("RGB"), dtype=np.int16)
    h = img.shape[0]
    sky_mask = np.abs(img - sky).max(axis=2) <= SKY_TOL
    water_mask = np.abs(img - nowater).max(axis=2) > WATER_TOL
    row0 = int(min(max(np.ceil(rec["horizon_row_px"]) + 2, 0), h))
    gap = float(sky_mask[row0:].sum()) / float(sky_mask.size)
    floating = water_mask[: h - FLOAT_FAR_ROWS] & sky_mask[FLOAT_NEAR_ROWS : h - FLOAT_FAR_ROWS + FLOAT_NEAR_ROWS] & sky_mask[FLOAT_FAR_ROWS:]
    return {
        "below_horizon_sky_frac": round(gap, 4),
        "floating_water_px": int(floating.sum()),
        "water_px": int(water_mask.sum()),
    }


def bar_value(bar, view, poses, tint, fog, edge=None, backdrop=None):
    """The measured value one bar judges: an aggregate over the bench poses, or a tint / fog field."""
    src = bar["source"]
    if src == "tint":
        return tint[bar["key"]]
    if src == "fog":
        return fog[bar["key"]]
    if src == "backdrop":
        return backdrop[bar["key"]]
    if src == "edge":
        return {"min": min, "max": max}[bar.get("agg", "max")]([e[bar["key"]] for e in edge])
    vals = [p[bar["key"]] for p in poses if bar.get("pose") in (None, p["id"])]
    return {"min": min, "max": max}[bar.get("agg", "min")](vals)


def judge_bars(view, poses, tint, fog, bars_doc, edge=None, backdrop=None):
    out = []
    for bar in bars_doc["bars"]:
        lim = bar["limit"]
        if isinstance(lim, dict):
            if view not in lim:
                continue
            lim = lim[view]
        v = bar_value(bar, view, poses, tint, fog, edge, backdrop)
        ok = {">=": v >= lim, "<=": v <= lim, "==": v == lim}[bar["op"]]
        out.append({"name": bar["name"], "pass": bool(ok), "value": v, "limit": lim, "op": bar["op"]})
    return out


def richness(out_dir):
    raw = load_json(os.path.join(out_dir, "raw.json"))
    bars_doc = load_json(os.path.join(HERE, "richness_bars.json"))
    poses = []
    for p in raw["poses"]:
        rec = dict(p)
        rec.update(richness_stats(p["png"]))
        poses.append(rec)
    edge = []
    for e in raw["edge_poses"]:
        rec = dict(e)
        rec.update(edge_stats(e))
        edge.append(rec)
    bars = judge_bars(raw["view"], poses, raw["tint"], raw["fog"], bars_doc, edge, raw["backdrop"])
    doc = {
        "generated_epoch": int(time.time()),
        "display": raw["display"],
        "headless": raw["headless"],
        "adapter": raw["adapter"],
        "godot_version": raw["godot_version"],
        "repo_commit": git_commit(),
        "xdg_data_home": os.environ.get("XDG_DATA_HOME", ""),
        "view": raw["view"],
        "mutate": raw["mutate"],
        "pass": all(b["pass"] for b in bars),
        "fog": raw["fog"],
        "tint": raw["tint"],
        "bars": bars,
        "poses": poses,
        "edge_poses": edge,
        "backdrop": raw["backdrop"],
    }
    with open(os.path.join(out_dir, "richness.json"), "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")
    for b in bars:
        print("  %-28s %s value=%s %s %s" % (b["name"], "ok  " if b["pass"] else "FAIL", b["value"], b["op"], b["limit"]))
    print("richness post: view=%s mutate=%s bars passing %d/%d" % (raw["view"], raw["mutate"], sum(1 for b in bars if b["pass"]), len(bars)))
    return 0 if doc["pass"] else 1


# ---------------------------------------------------------------- finish
def git_commit():
    try:
        out = subprocess.run(["git", "-C", REPO, "rev-parse", "HEAD"], capture_output=True, text=True, check=True)
        return out.stdout.strip()
    except (subprocess.CalledProcessError, OSError):
        return ""


def finish(out_dir):
    raw = load_json(os.path.join(out_dir, "raw.json"))
    doc = load_json(shots_path())
    thr = load_json(os.path.join(HERE, "thresholds.json"))
    authored_xz = {}
    for s in doc["shots"]:
        if not s.get("control"):
            authored_xz[s["id"]] = (float(s["cam"][0]), float(s["cam"][1]))
    shots = []
    for rec in raw["shots"]:
        sid = rec["id"]
        png = os.path.join(out_dir, "shot-%s.png" % sid)
        st = pixel_stats(png)
        im = Image.open(png).convert("RGB")
        im.save(os.path.join(out_dir, "shot-%s-1600.webp" % sid), "WEBP", quality=82, method=4)
        im.resize((800, 450), Image.LANCZOS).save(os.path.join(out_dir, "shot-%s-800.webp" % sid), "WEBP", quality=82, method=4)
        fails = judge(rec, st, thr, authored_xz if not rec["control"] else {})
        rs = richness_stats(png)
        es = edge_stats({"png": png, "nowater_png": os.path.join(out_dir, "aux-%s-nowater.png" % sid),
                         "sky_png": os.path.join(out_dir, "aux-%s-sky.png" % sid), "horizon_row_px": rec["horizon_row_px"]})
        rich_fails = judge_richness(rec, rs, thr)
        shots.append({
            "id": sid,
            "control": rec["control"],
            "subject": rec["subject"],
            "cam_pos": rec["cam_pos"],
            "fov_deg": rec["fov_deg"],
            "sun_elevation_deg": rec["sun_elevation_deg"],
            "clearance_m": rec["clearance_m"],
            "png_w": rec["png_w"],
            "png_h": rec["png_h"],
            "luma_range": st["luma_range"],
            "warm_cool": st["warm_cool"],
            "black_frac": st["black_frac"],
            "white_frac": st["white_frac"],
            "water_frac": rec["water_frac"],
            "river_bank_in_frame": bool(rec["river_authored"] or rec["river_measured"]),
            "river_authored": rec["river_authored"],
            "river_measured": rec["river_measured"],
            "river_rays": rec["river_rays"],
            "horizon_y_frac": rec["horizon_y_frac"],
            "homestead_in_frame": rec["homestead_in_frame"],
            "fog_density": rec["fog_density"],
            "view_distance": rec["view_distance"],
            "sky_frac": rs["sky_frac"],
            "detail": rs["detail"],
            "hue_bins": rs["hue_bins"],
            "far_ground_p90_m": rec["far_ground_p90_m"],
            "tree_far_p95_m": rec["tree_far_p95_m"],
            "species_ge10": rec["species_ge10"],
            "below_horizon_sky_frac": es["below_horizon_sky_frac"],
            "floating_water_px": es["floating_water_px"],
            "richness_fails": rich_fails,
            "fails": fails,
            "pass": len(fails) == 0 and len(rich_fails) == 0,
        })
    cands = [s for s in shots if not s["control"]]
    want = [s for s in doc["shots"] if not s.get("control")]
    cells, width = 0, 0
    if len(cands) == len(want) and len(cands) > 0:
        width = contact_sheet(out_dir, cands)
        cells = len(cands)
    manifest = {
        "generated_epoch": int(time.time()),
        "display": raw["display"],
        "headless": raw["headless"],
        "scene": raw["scene"],
        "godot_version": raw["godot_version"],
        "adapter": raw["adapter"],
        "repo_commit": git_commit(),
        "xdg_data_home": os.environ.get("XDG_DATA_HOME", ""),
        "water_time_frozen": raw["water_time_frozen"],
        "contact": {"cells": cells, "w": width},
        "shots": shots,
    }
    with open(os.path.join(out_dir, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
        f.write("\n")
    n_pass = sum(1 for s in cands if s["pass"])
    ctl = [s for s in shots if s["control"]]
    print("scenic post: %d shots, candidates passing %d/%d, control failing %s" % (
        len(shots), n_pass, len(cands), "yes" if ctl and not ctl[0]["pass"] else ("no" if ctl else "n/a")))
    return 0


# ---------------------------------------------------------------- compare
def frames_of(path):
    if os.path.isdir(path):
        return sorted(glob.glob(os.path.join(path, "shot-*.png")))
    return [path]


def compare(a, b):
    eq = "na"
    if os.path.isdir(a) and os.path.isdir(b):
        ma, mb = os.path.join(a, "manifest.json"), os.path.join(b, "manifest.json")
        if os.path.exists(ma) and os.path.exists(mb):
            da, db = load_json(ma), load_json(mb)
            da.pop("generated_epoch", None)
            db.pop("generated_epoch", None)
            eq = "1" if json.dumps(da, sort_keys=True) == json.dumps(db, sort_keys=True) else "0"
    fa, fb = frames_of(a), frames_of(b)
    pairs = list(zip(fa, fb))  # same shots pair by name (sorted); different shots pair by position
    sq, n = 0.0, 0
    for pa, pb in pairs:
        ia = np.asarray(Image.open(pa).convert("RGB"), dtype=np.float64)
        ib = np.asarray(Image.open(pb).convert("RGB"), dtype=np.float64)
        if ia.shape != ib.shape:
            ib = np.asarray(Image.open(pb).convert("RGB").resize((ia.shape[1], ia.shape[0]), Image.LANCZOS), dtype=np.float64)
        sq += float(((ia - ib) ** 2).sum())
        n += ia.size
    rms = (sq / n) ** 0.5 if n else 999.0
    print("SCENIC_DET manifest_equal=%s rms=%.3f" % (eq, rms))
    return 0


def main(argv):
    if len(argv) == 3 and argv[1] == "finish":
        return finish(argv[2])
    if len(argv) == 3 and argv[1] == "richness":
        return richness(argv[2])
    if len(argv) == 4 and argv[1] == "compare":
        return compare(argv[2], argv[3])
    sys.stderr.write("usage: post.py finish OUT_DIR | post.py richness OUT_DIR | post.py compare A B\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
