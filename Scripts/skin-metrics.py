#!/usr/bin/env python3
"""肤色量化工具：在检测到的人脸脸颊区域提取 Lab / ITA 统计量。

把「肤色自然不自然」换成可比较的数字，用于
  1) 对比原图与成片的调色偏移；
  2) 建立参考集（如某位修图师的成片）的目标分布。

依赖：numpy、pillow，以及同目录的 face-detect（macOS Vision 编译产物）

用法：
  python3 Scripts/skin-metrics.py 目录或图片...            # 批量量化
  python3 Scripts/skin-metrics.py --json out.json 目录
  python3 Scripts/skin-metrics.py --compare 原图.jpg 成片.jpg [--overlay 校验图.png]
"""

import argparse
import io
import json
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageCms

HERE = Path(__file__).resolve().parent
DETECTOR = HERE / "face-detect"
WORK_RGB = ImageCms.createProfile("sRGB")
IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".webp"}
M_RGB2XYZ = np.array(
    [
        [0.4124564, 0.3575761, 0.1804375],
        [0.2126729, 0.7151522, 0.0721750],
        [0.0193339, 0.1191920, 0.9503041],
    ]
)
WHITE_D65 = np.array([0.95047, 1.00000, 1.08883])


def open_srgb(path: Path, half: bool = True) -> Image.Image:
    """打开图片并统一到 sRGB。half=True 时对 JPEG 用半分辨率快速解码。"""
    im = Image.open(path)
    if half and im.format == "JPEG":
        im.draft("RGB", (im.size[0] // 2, im.size[1] // 2))
    icc = im.info.get("icc_profile")
    im = im.convert("RGB")
    if icc:
        try:
            src = ImageCms.ImageCmsProfile(io.BytesIO(icc))
            im = ImageCms.profileToProfile(im, src, WORK_RGB, outputMode="RGB")
        except Exception:
            pass  # ICC 不可解析时按 sRGB 解释
    return im


def to_lab(rgb: np.ndarray) -> tuple:
    lin = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
    xyz = lin @ M_RGB2XYZ.T
    t = xyz / WHITE_D65
    delta = 6.0 / 29.0
    f = np.where(t > delta**3, np.cbrt(t), t / (3 * delta**2) + 4.0 / 29.0)
    return 116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])


def detect_faces(paths: list) -> dict:
    """调用 Vision 工具批量检测人脸，返回 {路径: 结果}。"""
    if not DETECTOR.exists():
        print(f"缺少人脸检测工具 {DETECTOR}，请先编译：", file=sys.stderr)
        print("  swiftc -O -o Scripts/face-detect Scripts/face-detect.swift", file=sys.stderr)
        sys.exit(1)
    out = subprocess.run(
        [str(DETECTOR), *map(str, paths)], capture_output=True, text=True, check=True
    )
    try:
        data = json.loads(out.stdout)
    except json.JSONDecodeError:
        return {}
    return {d["image"]: d for d in data}


def cheek_mask(face: dict, w: int, h: int) -> np.ndarray:
    """按双眼与嘴的位置，在脸颊处生成两个椭圆采样区。"""
    lp, rp, m = face.get("leftPupil"), face.get("rightPupil"), face.get("mouth")
    if lp and rp and m:
        L = np.array(lp) * [w, h]
        R = np.array(rp) * [w, h]
        M = np.array(m) * [w, h]
        eye = (L + R) / 2
        d = float(np.linalg.norm(R - L))
        u = (R - L) / (np.linalg.norm(R - L) + 1e-6)
        v = M - eye
        centers = [eye + v * 0.55 + u * d * 0.38, eye + v * 0.55 - u * d * 0.38]
        rx, ry = d * 0.22, d * 0.20
    else:
        bx, by, bw, bh = face["bbox"]
        d = bw * w
        centers = [
            np.array([(bx + 0.30 * bw) * w, (by + 0.60 * bh) * h]),
            np.array([(bx + 0.70 * bw) * w, (by + 0.60 * bh) * h]),
        ]
        rx, ry = d * 0.16, d * 0.16

    yy, xx = np.mgrid[0:h, 0:w]
    mask = np.zeros((h, w), dtype=bool)
    for c in centers:
        mask |= ((xx - c[0]) / rx) ** 2 + ((yy - c[1]) / ry) ** 2 <= 1.0
    return mask


def robust(lab: tuple, mask: np.ndarray) -> dict:
    """在掩膜内做稳健截尾统计，排除混入的头发与高光。"""
    L, a, b = (ch[mask] for ch in lab)
    if L.size < 200:
        return {"ok": False, "reason": "脸颊像素不足"}
    keep = np.ones(L.shape, dtype=bool)
    for _ in range(2):  # 两轮迭代剔除离群点
        med = np.median(L[keep])
        mad = np.median(np.abs(L[keep] - med)) + 1e-6
        keep &= np.abs(L - med) <= 2.5 * 1.4826 * mad
        if keep.sum() < 200:
            break
    L, a, b = L[keep], a[keep], b[keep]
    C = np.hypot(a, b)
    hh = np.degrees(np.arctan2(b, a)) % 360
    ita = np.degrees(np.arctan((L - 50) / np.maximum(b, 1e-3)))
    return {
        "ok": True,
        "n_px": int(L.size),
        "L": float(np.median(L)),
        "a": float(np.median(a)),
        "b": float(np.median(b)),
        "C": float(np.median(C)),
        "h": float(np.median(hh)),
        "ITA": float(np.median(ita)),
        "L_p10": float(np.percentile(L, 10)),
        "L_p90": float(np.percentile(L, 90)),
        "clip_hi": float((L > 95).mean()),
        "clip_lo": float((L < 15).mean()),
    }


def analyze(path: Path, face: dict, half: bool = True) -> dict:
    im = open_srgb(path, half=half)
    w, h = im.size
    mask = cheek_mask(face, w, h)
    ys, xs = np.nonzero(mask)
    if xs.size == 0:
        return {"ok": False, "reason": "采样区越界"}
    pad = 4
    x0, x1 = max(xs.min() - pad, 0), min(xs.max() + pad, w)
    y0, y1 = max(ys.min() - pad, 0), min(ys.max() + pad, h)
    crop_mask = mask[y0:y1, x0:x1]
    crop = np.asarray(im.crop((x0, y0, x1, y1)), dtype=np.float32) / 255.0
    r = robust(to_lab(crop), crop_mask)
    r["image_size"] = [w, h]
    return r


def run(targets: list) -> list:
    files = []
    for t in targets:
        p = Path(t)
        if p.is_dir():
            files += sorted(f for f in p.rglob("*") if f.suffix.lower() in IMAGE_SUFFIXES)
        elif p.is_file():
            files.append(p)
        else:
            print(f"跳过不存在的路径：{t}", file=sys.stderr)
    if not files:
        print("没有找到可分析的图片", file=sys.stderr)
        sys.exit(1)

    faces = detect_faces(files)
    rows = []
    for f in files:
        rec = faces.get(str(f), {})
        fl = rec.get("faces") or []
        if not fl:
            rows.append({"file": str(f), "ok": False, "reason": "未检测到人脸", "faces": 0})
            continue
        # 多人场景以面积最大的人脸为准
        best = max(fl, key=lambda x: x["bbox"][2] * x["bbox"][3])
        try:
            r = analyze(f, best)
        except Exception as exc:
            rows.append({"file": str(f), "ok": False, "reason": f"读取失败 {exc}", "faces": len(fl)})
            continue
        r.update({"file": str(f), "faces": len(fl)})
        rows.append(r)
    return rows


def print_table(rows: list) -> None:
    head = f"{'文件':<32}{'人数':>4}{'L*':>7}{'a*':>7}{'b*':>7}{'C*':>7}{'h°':>7}{'ITA':>8}{'溢出':>7}"
    print(head)
    print("-" * len(head))
    for r in rows:
        name = Path(r["file"]).name[:30]
        if not r.get("ok"):
            print(f"{name:<32}{r.get('faces', 0):>4}  {r['reason']}")
            continue
        print(
            f"{name:<32}{r['faces']:>4}{r['L']:>7.1f}{r['a']:>7.1f}{r['b']:>7.1f}"
            f"{r['C']:>7.1f}{r['h']:>7.1f}{r['ITA']:>8.1f}{r['clip_hi'] * 100:>6.1f}%"
        )


def summarize(rows: list, label: str = "") -> None:
    good = [r for r in rows if r.get("ok")]
    if not good:
        return
    arr = np.array([[r["L"], r["a"], r["b"], r["C"], r["h"], r["ITA"]] for r in good])
    tag = f"{label}（n={len(good)}）" if label else f"集合统计（n={len(good)}）"
    print(f"\n{tag}")
    print(
        f"  L* {arr[:, 0].mean():.1f} ± {arr[:, 0].std():.1f}"
        f"    C* {arr[:, 3].mean():.1f} ± {arr[:, 3].std():.1f}"
        f"    h° {arr[:, 4].mean():.1f} ± {arr[:, 4].std():.1f}"
        f"    ITA {arr[:, 5].mean():.1f} ± {arr[:, 5].std():.1f}"
    )
    print(
        f"  色相角集中在 {np.percentile(arr[:, 4], 10):.0f}–{np.percentile(arr[:, 4], 90):.0f}°，"
        f"ITA 区间 {np.percentile(arr[:, 5], 10):.0f}–{np.percentile(arr[:, 5], 90):.0f}°"
    )


def compare(src: Path, dst: Path, overlay: Path = None) -> None:
    faces = detect_faces([src, dst])
    res = {}
    for p in (src, dst):
        fl = (faces.get(str(p)) or {}).get("faces") or []
        if not fl:
            print(f"{p.name}：未检测到人脸，无法对比")
            return
        res[p] = analyze(p, max(fl, key=lambda x: x["bbox"][2] * x["bbox"][3]))

    A, B = res[src], res[dst]
    print(f"原图：{src.name}")
    print(f"成片：{dst.name}\n")
    fields = ["L", "a", "b", "C", "h", "ITA"]
    labels = {"L": "亮度 L*", "a": "红绿 a*", "b": "黄蓝 b*", "C": "彩度 C*", "h": "色相 h°", "ITA": "肤色角 ITA°"}
    print(f"{'指标':<12}{'原图':>9}{'成片':>9}{'偏移':>9}")
    print("-" * 39)
    for k in fields:
        print(f"{labels[k]:<12}{A[k]:>9.2f}{B[k]:>9.2f}{B[k] - A[k]:>+9.2f}")
    print(f"\n亮度区间  原图 {A['L_p10']:.0f}–{A['L_p90']:.0f}   成片 {B['L_p10']:.0f}–{B['L_p90']:.0f}")
    print(f"高光溢出  原图 {A['clip_hi'] * 100:.1f}%   成片 {B['clip_hi'] * 100:.1f}%")
    print(f"采样像素  {A['n_px']} / {B['n_px']}")

    if overlay:
        faces_dst = (faces.get(str(dst)) or {}).get("faces") or []
        best = max(faces_dst, key=lambda x: x["bbox"][2] * x["bbox"][3])
        im = open_srgb(dst).convert("RGB")
        w, h = im.size
        m = cheek_mask(best, w, h)
        ys, xs = np.nonzero(m)
        pad = int((xs.max() - xs.min()) * 0.7)
        box = (max(xs.min() - pad, 0), max(ys.min() - pad, 0),
               min(xs.max() + pad, w), min(ys.max() + pad, h))
        arr = np.asarray(im.crop(box)).copy()
        sub = m[box[1]:box[3], box[0]:box[2]]
        arr[sub] = (arr[sub] * 0.45 + np.array([0, 210, 90]) * 0.55).astype(np.uint8)
        Image.fromarray(arr).resize(
            (min(560, arr.shape[1] * 3), min(560, arr.shape[0] * 3)), Image.LANCZOS
        ).save(overlay)
        print(f"\n采样区校验图：{overlay}")


def main() -> None:
    ap = argparse.ArgumentParser(description="人脸肤色 Lab / ITA 量化")
    ap.add_argument("targets", nargs="*", help="图片路径或目录")
    ap.add_argument("--json", help="结果写入 JSON")
    ap.add_argument("--compare", nargs=2, metavar=("原图", "成片"))
    ap.add_argument("--overlay", help="对比时输出采样区校验图")
    args = ap.parse_args()

    if args.compare:
        compare(Path(args.compare[0]), Path(args.compare[1]), Path(args.overlay) if args.overlay else None)
        return

    if not args.targets:
        ap.error("需要提供图片或目录")
    rows = run(args.targets)
    print_table(rows)
    summarize(rows)
    if args.json:
        Path(args.json).write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"\n已写入 {args.json}")


if __name__ == "__main__":
    main()
