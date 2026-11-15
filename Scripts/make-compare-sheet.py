#!/usr/bin/env python3
"""生成「原图 / 成片」对比图：整幅并排 + 面部同框特写 + 肤色指标。

用法：
  python3 Scripts/make-compare-sheet.py 原图.jpg 成片.jpg --out 对比.png \
      --label-a "原始 JPEG" --label-b "肤色锚定后"
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageOps

HERE = Path(__file__).resolve().parent
DETECTOR = HERE / "face-detect"
FONT = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"


def load(path):
    return ImageOps.exif_transpose(Image.open(path)).convert("RGB")


def detect(img):
    probe = Path("/tmp") / "._cmp_probe.png"
    tmp = img.copy()
    tmp.thumbnail((2000, 2000), Image.LANCZOS)
    tmp.save(probe)
    out = json.loads(subprocess.run([str(DETECTOR), str(probe)], capture_output=True, text=True).stdout)[0]
    probe.unlink(missing_ok=True)
    faces = out.get("faces") or []
    if not faces:
        return None
    return max(faces, key=lambda x: x["bbox"][2] * x["bbox"][3])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("before")
    ap.add_argument("after")
    ap.add_argument("--out", required=True)
    ap.add_argument("--label-a", default="原始")
    ap.add_argument("--label-b", default="修正后")
    ap.add_argument("--metrics", help="皮肤指标 JSON，含 before/after")
    args = ap.parse_args()

    A, B = load(args.before), load(args.after)
    if A.size != B.size:
        B = B.resize(A.size, Image.LANCZOS)
    W, H = A.size

    face = detect(A)
    if face is None:
        sys.exit("未检测到人脸，无法生成面部特写")

    bx, by, bw, bh = face["bbox"]
    fx, fy, fw, fh = bx * W, by * H, bw * W, bh * H
    side = int(fw * 2.3)
    cx, cy = fx + fw / 2, fy + fh / 2
    x0 = int(max(0, min(W - side, cx - side / 2)))
    y0 = int(max(0, min(H - side, cy - side / 2)))
    box = (x0, y0, x0 + side, y0 + side)

    PANEL_H = 880
    PANEL_W = int(PANEL_H * W / H)
    CLOSE = 540
    try:
        F1 = ImageFont.truetype(FONT, 26)
        F2 = ImageFont.truetype(FONT, 19)
        F3 = ImageFont.truetype(FONT, 16)
    except Exception:
        F1 = F2 = F3 = ImageFont.load_default()

    PAD, GAP, HEAD = 26, 20, 44
    sw = PAD * 2 + PANEL_W * 2 + GAP
    sh = PAD * 2 + HEAD + PANEL_H + GAP + 34 + CLOSE + 56
    sheet = Image.new("RGB", (sw, sh), (249, 248, 246))
    dr = ImageDraw.Draw(sheet)

    y = PAD
    dr.text((PAD, y), args.label_a, font=F1, fill=(35, 35, 35))
    dr.text((PAD + PANEL_W + GAP, y), args.label_b, font=F1, fill=(35, 35, 35))
    y += HEAD
    sheet.paste(A.resize((PANEL_W, PANEL_H), Image.LANCZOS), (PAD, y))
    sheet.paste(B.resize((PANEL_W, PANEL_H), Image.LANCZOS), (PAD + PANEL_W + GAP, y))

    y += PANEL_H + GAP
    dr.text((PAD, y), "面部同框特写", font=F2, fill=(80, 80, 80))
    y += 30
    sheet.paste(A.crop(box).resize((CLOSE, CLOSE), Image.LANCZOS), (PAD, y))
    sheet.paste(B.crop(box).resize((CLOSE, CLOSE), Image.LANCZOS), (PAD + PANEL_W + GAP, y))
    y += CLOSE + 20

    if args.metrics and Path(args.metrics).exists():
        m = json.loads(Path(args.metrics).read_text(encoding="utf-8"))
        b4, af = m["before"], m["after"]
        pairs = [("L*", b4["L"], af["L"]), ("C*", b4["C"], af["C"]),
                 ("h°", b4["h"], af["h"]), ("ITA", b4["ITA"], af["ITA"])]
        seg = (sw - PAD * 2) // len(pairs)
        for i, (name, v0, v1) in enumerate(pairs):
            dr.text((PAD + i * seg, y), f"{name}  {v0:.1f} → {v1:.1f}", font=F3, fill=(95, 95, 95))

    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    sheet.save(args.out)
    print(f"已生成 {args.out}  {sheet.size[0]}×{sheet.size[1]}")


if __name__ == "__main__":
    main()
