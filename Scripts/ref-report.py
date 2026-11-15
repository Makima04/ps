"""对一批人像成片做统一量化：肤色、影调、主体/背景分离、背景色彩统一度。

用法：
    python3 Scripts/ref-report.py <图片或目录> [...] --json out.json
"""
import argparse
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("sm", HERE / "skin-metrics.py")
sm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sm)

MASKER = HERE / "person-mask"


def circular_std(deg: np.ndarray) -> float:
    r = np.radians(deg)
    R = np.hypot(np.cos(r).mean(), np.sin(r).mean())
    return float(np.degrees(np.sqrt(-2 * np.log(max(R, 1e-6)))))


def measure(path: Path) -> dict:
    im = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
    W, H = im.size

    probe = Path("/tmp/_rr.jpg")
    im.save(probe, quality=95)
    det = json.loads(subprocess.run([str(sm.DETECTOR), str(probe)],
                                    capture_output=True, text=True).stdout)[0]
    faces = det.get("faces") or []
    rec = {"file": path.name, "size": [W, H], "faces": len(faces)}

    if faces:
        face = max(faces, key=lambda x: x["bbox"][2] * x["bbox"][3])
        rec["face"] = sm.analyze(probe, face, half=False)
        bx, by, bw, bh = face["bbox"]
        rec["face_box"] = [round(v, 4) for v in (bx, by, bw, bh)]

    small = im.copy()
    small.thumbnail((1100, 1100), Image.LANCZOS)
    tmp, msk = Path("/tmp/_rr2.jpg"), Path("/tmp/_rr2.png")
    small.save(tmp, quality=96)
    subprocess.run([str(MASKER), str(tmp), str(msk)], capture_output=True)

    arr = np.asarray(small, dtype=np.float32) / 255.0
    L, a, b = sm.to_lab(arr)
    C = np.hypot(a, b)
    h = np.degrees(np.arctan2(b, a)) % 360

    g = {
        "L_p01": float(np.percentile(L, 1)),
        "L_p50": float(np.percentile(L, 50)),
        "L_p99": float(np.percentile(L, 99)),
        "L_std": float(L.std()),
        "clip_hi": float((L > 98).mean()),
        "clip_lo": float((L < 2).mean()),
        "C_mean": float(C.mean()),
    }

    if msk.exists():
        m = np.asarray(Image.open(msk).convert("L").resize(small.size,
                        Image.LANCZOS)) > 127
        if m.mean() > 0.02 and (~m).mean() > 0.02:
            fg, bg = m, ~m
            g.update({
                "fg_L": float(np.median(L[fg])),
                "fg_frac": float(fg.mean()),
                "bg_L": float(np.median(L[bg])),
                "bg_C": float(np.median(C[bg])),
                "bg_b": float(np.median(b[bg])),
                "bg_a": float(np.median(a[bg])),
                "bg_h": float(np.median(h[bg])),
                "bg_h_spread": circular_std(h[bg]),
                "bg_L_std": float(L[bg].std()),
                "sep_L": float(np.median(L[fg]) - np.median(L[bg])),
            })
    rec["global"] = g
    return rec


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("targets", nargs="+")
    ap.add_argument("--json")
    ap.add_argument("--label", default="")
    args = ap.parse_args()

    files = []
    for t in args.targets:
        p = Path(t)
        if p.is_dir():
            files += sorted(f for f in p.iterdir()
                            if f.suffix.lower() in {".jpg", ".jpeg", ".png", ".webp"})
        else:
            files.append(p)

    rows = []
    for f in files:
        try:
            r = measure(f)
        except Exception as e:
            print(f"跳过 {f.name}: {e}", file=sys.stderr)
            continue
        rows.append(r)
        fa, g = r.get("face") or {}, r["global"]
        skin = (f"L*{fa['L']:5.1f} C*{fa['C']:5.1f} h°{fa['h']:5.1f} ITA{fa['ITA']:6.1f}"
                if fa.get("ok") else (f"  {fa.get('reason','未检出人脸')}  " if fa else "  未检出人脸  "))
        print(f"{r['file'][-14:]:>16}  {skin} | "
              f"p50 {g['L_p50']:5.1f} σ{g['L_std']:4.1f} 溢 {g['clip_hi']*100:4.1f}% | "
              f"主体 {g.get('fg_L', float('nan')):5.1f} 背景 {g.get('bg_L', float('nan')):5.1f} "
              f"Δ{g.get('sep_L', float('nan')):+5.1f} | 背景C*{g.get('bg_C', float('nan')):5.1f} "
              f"h{g.get('bg_h', float('nan')):5.1f}±{g.get('bg_h_spread', float('nan')):4.1f}")

    if len(rows) > 1:
        print("\n—— 汇总 ——")
        def agg(getter, name, fmt="{:7.2f}"):
            vals = [v for v in (getter(r) for r in rows) if v is not None and not np.isnan(v)]
            if not vals:
                return
            print(f"{name:<16}均值 {fmt.format(np.mean(vals))}   "
                  f"范围 {fmt.format(min(vals))} – {fmt.format(max(vals))}   "
                  f"σ {fmt.format(np.std(vals))}")
        agg(lambda r: (r.get("face") or {}).get("L"), "肤色 L*")
        agg(lambda r: (r.get("face") or {}).get("C"), "肤色 C*")
        agg(lambda r: (r.get("face") or {}).get("h"), "肤色 h°")
        agg(lambda r: (r.get("face") or {}).get("ITA"), "肤色 ITA")
        agg(lambda r: r["global"]["L_p50"], "全图 p50")
        agg(lambda r: r["global"].get("bg_L"), "背景 L*")
        agg(lambda r: r["global"].get("bg_C"), "背景 C*")
        agg(lambda r: r["global"].get("sep_L"), "分离 ΔL")
        agg(lambda r: r["global"]["clip_hi"] * 100, "高光溢出 %")

    if args.json:
        Path(args.json).write_text(json.dumps(rows, ensure_ascii=False, indent=2))
        print(f"\n已写入 {args.json}")


if __name__ == "__main__":
    main()
