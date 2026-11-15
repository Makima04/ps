"""把分层色度画到 a*b* 平面上：层与层离得越远，越不容易混淆。

用法：
    python3 Scripts/layer-plot.py <图片或目录> [...] --out plot.png
目录会聚成一层点云（空心小圈），单张图会画实心点。
"""
import argparse
import importlib.util
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("sp", HERE / "skin-split.py")
sp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sp)

FONT = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"
ORDER = ["cloth", "bg", "skin_body", "skin_face"]
COLORS = {
    "skin_face": (226, 110, 30),
    "skin_body": (26, 158, 150),
    "cloth": (58, 96, 200),
    "bg": (176, 84, 140),
}
LABELS = {"skin_face": "面部皮肤", "skin_body": "肢体皮肤", "cloth": "服装", "bg": "背景"}


def collect(path) -> dict:
    d = sp.compute(path)
    out = {}
    for k in COLORS:
        s = sp.layer_stats(d, d[k], min_px=200)
        out[k] = s if s.get("ok") else None
    return {"file": Path(path).name, "layers": out}


def draw_panel(dr, ox, oy, size, rows, title, f1, f2, lo, hi):
    dr.rectangle([ox, oy, ox + size, oy + size], fill=(253, 252, 250),
                 outline=(215, 212, 206))
    span = hi - lo
    cx = ox + size / 2 + (-(lo + hi) / 2) * (size / span) * -1
    cy = oy + size / 2 + ((lo + hi) / 2) * (size / span)
    k = size / span

    def X(a):
        return cx + a * k

    def Y(b):
        return cy - b * k

    step = 10 if span <= 80 else 20
    v = int(np.ceil(lo / step) * step)
    while v <= hi:
        dr.line([X(v), oy, X(v), oy + size], fill=(240, 238, 233))
        dr.line([ox, Y(v), ox + size, Y(v)], fill=(240, 238, 233))
        v += step
    dr.line([X(0), oy, X(0), oy + size], fill=(186, 182, 176), width=2)
    dr.line([ox, Y(0), ox + size, Y(0)], fill=(186, 182, 176), width=2)
    dr.text((ox + 10, oy + 8), title, font=f1, fill=(28, 28, 28))
    dr.text((ox + size - 64, Y(0) + 4), "+a* 红", font=f2, fill=(150, 146, 140))
    dr.text((ox + 6, Y(0) + 4), "−a* 绿", font=f2, fill=(150, 146, 140))
    dr.text((ox + size / 2 + 6, oy + 8), "+b* 黄", font=f2, fill=(150, 146, 140))
    dr.text((ox + size / 2 + 6, oy + size - 22), "−b* 蓝", font=f2, fill=(150, 146, 140))

    pts = {}
    for row in rows:
        for key in ORDER:
            s = row["layers"][key]
            if s:
                pts.setdefault(key, []).append((s["a"], s["b"], s["C"], s["h"]))

    for key in ORDER:
        if key not in pts:
            continue
        ps = pts[key]
        col = COLORS[key]
        if len(ps) > 1:
            for a, b, _, _ in ps:
                x, y = X(a), Y(b)
                dr.ellipse([x - 4, y - 4, x + 4, y + 4], outline=col, width=1)
        a = float(np.median([p[0] for p in ps]))
        b = float(np.median([p[1] for p in ps]))
        C = float(np.median([p[2] for p in ps]))
        r = 7 + min(8, C * 0.16)
        dr.ellipse([X(a) - r, Y(b) - r, X(a) + r, Y(b) + r], fill=col,
                   outline=(255, 255, 255), width=2)

    if "skin_face" in pts and "bg" in pts:
        a1 = float(np.median([p[0] for p in pts["skin_face"]]))
        b1 = float(np.median([p[1] for p in pts["skin_face"]]))
        a2 = float(np.median([p[0] for p in pts["bg"]]))
        b2 = float(np.median([p[1] for p in pts["bg"]]))
        dr.line([X(a1), Y(b1), X(a2), Y(b2)], fill=(120, 120, 120), width=2)
        dE = float(np.hypot(a1 - a2, b1 - b2))
        dr.text(((X(a1) + X(a2)) / 2 + 6, (Y(b1) + Y(b2)) / 2 - 20),
                f"ΔE {dE:.0f}", font=f2, fill=(90, 90, 90))

    # 图例（放在图下方，避免与点重叠）
    ly = oy + size + 10
    for key in ORDER:
        if key not in pts:
            continue
        ps = pts[key]
        C = float(np.median([p[2] for p in ps]))
        hh = [p[3] for p in ps if p[3] is not None]
        hs = f"  h°{np.median(hh):.0f}" if hh else ""
        dr.ellipse([ox + 2, ly + 3, ox + 14, ly + 15], fill=COLORS[key])
        dr.text((ox + 20, ly), f"{LABELS[key]}  C*{C:.0f}{hs}", font=f2,
                fill=(80, 80, 80))
        ly += 22


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("targets", nargs="+")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    groups = []
    for t in args.targets:
        p = Path(t)
        if p.is_dir():
            groups.append((p.name, sorted(f for f in p.iterdir()
                                          if f.suffix.lower() in {".jpg", ".png"})))
        else:
            groups.append((t if len(t) < 16 else Path(t).stem[-12:], [p]))

    data = []
    for name, files in groups:
        rows = []
        for f in files:
            try:
                rows.append(collect(f))
            except SystemExit:
                continue
        data.append((name, rows))

    allpts = [(s["a"], s["b"]) for _, rows in data for r in rows
              for k, s in r["layers"].items() if s]
    if not allpts:
        raise SystemExit("没有可绘制的分层数据")
    as_ = [p[0] for p in allpts]
    bs = [p[1] for p in allpts]
    lo = min(min(as_), min(bs)) - 10
    hi = max(max(as_), max(bs)) + 10

    f1 = ImageFont.truetype(FONT, 22)
    f2 = ImageFont.truetype(FONT, 16)
    S, GAP, PAD, LEG = 660, 26, 28, 100
    W = PAD * 2 + S * len(data) + GAP * (len(data) - 1)
    H = PAD * 2 + 44 + S + LEG
    img = Image.new("RGB", (W, H), (255, 255, 255))
    dr = ImageDraw.Draw(img)
    for i, (name, rows) in enumerate(data):
        draw_panel(dr, PAD + i * (S + GAP), PAD + 44, S, rows, name, f1, f2, lo, hi)
    img.save(args.out)
    print(f"已输出 {args.out} {img.size}   坐标范围 {lo:.0f} … {hi:.0f}")


if __name__ == "__main__":
    main()
