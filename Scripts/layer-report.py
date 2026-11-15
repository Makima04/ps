"""分层色彩报告：把一张图拆成 皮肤 / 服装 / 背景 三层，测各自的色度位置与层间距离。

「肤色会不会和背景或衣服混淆」不是看绝对彩度，而是看三层在 a*b* 平面上离得多远，
以及背景本身有没有色相身份。分层由 Scripts/skin-split.py 提供。

用法：
    python3 Scripts/layer-report.py <图片或目录> [--json out.json] [--overlay-dir 目录]
"""
import argparse
import importlib.util
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("sp", HERE / "skin-split.py")
sp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sp)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("targets", nargs="+")
    ap.add_argument("--json")
    ap.add_argument("--overlay-dir", help="可选：为每张图输出分层贴图")
    args = ap.parse_args()

    files = []
    for t in args.targets:
        p = Path(t)
        files += (sorted(f for f in p.iterdir()
                         if f.suffix.lower() in {".jpg", ".jpeg", ".png"})
                  if p.is_dir() else [p])

    if args.overlay_dir:
        Path(args.overlay_dir).mkdir(parents=True, exist_ok=True)

    rows = []
    print(f"{'文件':>20} {'面部 C/h':>14} {'肢体 C/h':>14} {'服装 C/h':>14} "
          f"{'背景 C/h':>14} {'肤/景':>6} {'Δh':>6} {'可见':>6}  判定")
    for f in files:
        try:
            d = sp.compute(f)
        except SystemExit:
            print(f"{f.name[-20:]:>20}  未检出人脸，跳过")
            continue
        except Exception as e:
            print(f"跳过 {f.name}: {e}", file=sys.stderr)
            continue
        stats = {k: sp.layer_stats(d, d[k]) for k in ("skin_face", "skin_body", "cloth", "bg")}
        rel = sp.relations(stats)
        notes = sp.verdict(rel, stats)
        rows.append({"file": f.name, "layers": stats, "rel": rel, "verdict": notes})

        def fmt(layer):
            if not layer.get("ok"):
                return "      —       "
            hh = f"{layer['h']:5.1f}" if layer.get("h") is not None else "  n/a"
            return f"{layer['C']:5.1f} /{hh}"

        dh = f"{rel['dh_skin_bg']:6.1f}" if rel.get("dh_skin_bg") is not None else "   n/a"
        print(f"{f.name[-20:]:>20} {fmt(stats['skin_face'])} {fmt(stats['skin_body'])} "
              f"{fmt(stats['cloth'])} {fmt(stats['bg'])} "
              f"{rel.get('C_skin_over_bg', float('nan')):6.2f} {dh} "
              f"{rel.get('visible_sep', 0):6.1f}  " + "；".join(notes))

        if args.overlay_dir:
            sp.overlay(d).save(Path(args.overlay_dir) / f"{f.stem}-layers.png")

    if args.json:
        Path(args.json).write_text(json.dumps(rows, ensure_ascii=False, indent=2))
        print(f"已写入 {args.json}")


if __name__ == "__main__":
    main()
