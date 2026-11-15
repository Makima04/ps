"""把分层结果导出成可直接使用的蒙版文件（原始分辨率、8 位灰度、带软边）。

每张图输出一个目录：
    <out>/<stem>/face.png      面部皮肤（含颈部、耳朵）
    <out>/<stem>/body.png      肢体皮肤（手、臂、肩、腿）
    <out>/<stem>/cloth.png     服装 + 头发 + 配饰
    <out>/<stem>/bg.png        背景
    <out>/<stem>/overlay.png   四层着色校验图（缩小版，用于肉眼核对）
    <out>/<stem>/report.json   各层面积占比、Lab 读数、层间关系与判定

蒙版尺寸与 EXIF 转正后的原图一致，可直接叠回原图使用。

用法：
    python3 Scripts/export-masks.py <图片或目录> --out-dir <目录>
    python3 Scripts/export-masks.py <目录> --out-dir <目录> --recursive
    python3 Scripts/export-masks.py <图片> --out-dir <目录> --only-skin   # 只出皮肤相关
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import importlib.util

_spec = importlib.util.spec_from_file_location("ss", HERE / "skin-split.py")
ss = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ss)

LAYERS = ("skin_face", "skin_body", "cloth", "bg")
FILES = {"skin_face": "face.png", "skin_body": "body.png",
         "cloth": "cloth.png", "bg": "bg.png"}
LABELS = {"skin_face": "面部皮肤", "skin_body": "肢体皮肤",
          "cloth": "服装/头发", "bg": "背景"}

IMG_EXT = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".heic", ".arw", ".dng"}


def to_full(mask_small: np.ndarray, size: tuple) -> Image.Image:
    """把低分辨率布尔蒙版放大到原图尺寸，返回带软边的 8 位灰度图。"""
    im = Image.fromarray((mask_small * 255).astype(np.uint8), mode="L")
    if im.size != size:
        im = im.resize(size, Image.LANCZOS)
    return im


def export_one(src: Path, out_root: Path, long_edge: int, only_skin: bool) -> dict:
    d = ss.compute(src, long_edge=long_edge)
    full_w, full_h = d["image"].size
    # 原图尺寸（EXIF 转正后），蒙版按此尺寸交付
    from PIL import ImageOps
    with Image.open(src) as raw:
        full_size = ImageOps.exif_transpose(raw).size

    stats = {k: ss.layer_stats(d, d[k]) for k in LAYERS}
    rel = ss.relations(stats)
    notes = ss.verdict(rel, stats)

    dst = out_root / src.stem
    dst.mkdir(parents=True, exist_ok=True)
    for key in (("skin_face", "skin_body") if only_skin else LAYERS):
        to_full(d[key], full_size).save(dst / FILES[key])

    ss.overlay(d).save(dst / "overlay.png")

    rec = {
        "file": str(src),
        "mask_size": list(full_size),
        "compute_size": [full_w, full_h],
        "skin_ref": {k: d["ref"][k] for k in ("L", "a", "b", "C", "h")},
        "layers": {}, "relations": rel, "notes": notes,
    }
    for k in LAYERS:
        s = stats[k]
        rec["layers"][k] = ({
            "frac": round(s["frac"], 4),
            "L": round(s["L"], 2), "C": round(s["C"], 2),
            "h": round(s["h"], 2) if s["h"] is not None else None,
        } if s.get("ok") else {"frac": round(s["frac"], 4), "ok": False})
    (dst / "report.json").write_text(json.dumps(rec, ensure_ascii=False, indent=2))
    return rec


def collect(targets: list, recursive: bool) -> list:
    out = []
    for t in targets:
        p = Path(t)
        if p.is_dir():
            it = p.rglob("*") if recursive else p.glob("*")
            out += [q for q in sorted(it) if q.suffix.lower() in IMG_EXT]
        elif p.is_file():
            out.append(p)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("targets", nargs="+")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--long-edge", type=int, default=1600,
                    help="分层计算用的长边像素，默认 1600")
    ap.add_argument("--recursive", action="store_true")
    ap.add_argument("--only-skin", action="store_true",
                    help="只导出 face/body 两层")
    args = ap.parse_args()

    files = collect(args.targets, args.recursive)
    if not files:
        sys.exit("没有找到图片")
    out_root = Path(args.out_dir)
    out_root.mkdir(parents=True, exist_ok=True)

    records = []
    print(f"{'文件':>16} {'面部%':>6} {'肢体%':>6} {'服装%':>6} {'背景%':>6}  "
          f"{'肤/景':>5} {'可见':>5}  判定")
    print("-" * 96)
    for f in files:
        try:
            rec = export_one(f, out_root, args.long_edge, args.only_skin)
        except SystemExit as e:
            print(f"{f.name[-16:]:>16}  跳过：{e}")
            continue
        L = rec["layers"]
        def pct(key):
            return f"{L[key]['frac'] * 100:6.1f}"
        print(f"{f.name[-16:]:>16} {pct('skin_face')} {pct('skin_body')} "
              f"{pct('cloth')} {pct('bg')}  "
              f"{rec['relations'].get('C_skin_over_bg', float('nan')):5.2f} "
              f"{rec['relations'].get('visible_sep', 0):5.0f}  "
              + "；".join(rec["notes"]))
        records.append(rec)

    (out_root / "manifest.json").write_text(
        json.dumps(records, ensure_ascii=False, indent=2))
    print(f"\n共 {len(records)} 张，输出到 {out_root}")
    print(f"清单：{out_root / 'manifest.json'}")


if __name__ == "__main__":
    main()
