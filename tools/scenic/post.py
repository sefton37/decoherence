#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Spec 577 S2a post-processing for the scenic render tool.

Two modes, both read-only with respect to the game frames:

  post.py finish OUT_DIR   reads OUT_DIR/raw.json (written by scenic_shots.gd) and the saved shot PNGs,
                           measures the pixel statistics, judges every shot against thresholds.json, writes
                           the 1600 and 800 px WebP copies, the contact sheet and manifest.json.
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
        label = "%s | fov %g | sun %g | %s | %s" % (s["id"], s["fov_deg"], s["sun_elevation_deg"], river, tag)
        d.text((x + 2, y + CELL_H + 4), label, fill=(235, 235, 235), font=font)
    sheet.save(os.path.join(out_dir, "contact.png"), "PNG")
    return w


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
            "fails": fails,
            "pass": len(fails) == 0,
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
    if len(argv) == 4 and argv[1] == "compare":
        return compare(argv[2], argv[3])
    sys.stderr.write("usage: post.py finish OUT_DIR | post.py compare A B\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
