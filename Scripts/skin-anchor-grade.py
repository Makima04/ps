#!/usr/bin/env python3
"""肤色锚定调色：以测得的肤色色相为锚点，只改彩度与亮度，不移动色相。

思路来自肤色量化结论：h° 是被摄者稳定的肤色签名，L* 随光照大幅波动，
所以修正视频色时应当「锁色相、动彩度、控亮度」。

用法：
  python3 Scripts/skin-anchor-grade.py 原图.jpg --out-dir 输出目录 \
      --target-c 30 --lift 0.7
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

# 复用肤色量化工具里的 Lab 转换与人脸采样逻辑
spec = importlib.util.spec_from_file_location("skinmetrics", HERE / "skin-metrics.py")
sm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sm)

M_XYZ2RGB = np.linalg.inv(sm.M_RGB2XYZ)


def lab_to_srgb(L, a, b):
    fy = (L + 16) / 116
    fx = fy + a / 500
    fz = fy - b / 200
    delta = 6.0 / 29.0
    f = np.stack([fx, fy, fz], axis=-1)
    t = np.where(f > delta, f**3, 3 * delta**2 * (f - 4.0 / 29.0))
    xyz = t * sm.WHITE_D65
    lin = xyz @ M_XYZ2RGB.T
    lin = np.clip(lin, 0, 1)
    srgb = np.where(lin <= 0.0031308, lin * 12.92, 1.055 * lin ** (1 / 2.4) - 0.055)
    return np.clip(srgb, 0, 1)


def smoothstep(x, lo, hi):
    t = np.clip((x - lo) / max(hi - lo, 1e-6), 0, 1)
    return t * t * (3 - 2 * t)


def skin_weight(L, C, h, h_center, h_width=26.0):
    """按色相、彩度、亮度三重软权重圈定皮肤，避免波及白纱与粉色裙摆。

    色相窗口要足够宽：泛红的斑块色相偏离中心最多，若衰减太快会正好漏掉
    最需要修正的区域。
    """
    dh = np.abs(h - h_center)
    dh = np.minimum(dh, 360 - dh)
    w_h = np.exp(-((dh / h_width) ** 2))
    w_c = smoothstep(C, 3, 12) * (1 - smoothstep(C, 52, 70))
    w_l = smoothstep(L, 15, 30) * (1 - smoothstep(L, 90, 98))
    return w_h * w_c * w_l


def grade(arr, h_center, c_scale, lift):
    L, a, b = sm.to_lab(arr)
    C = np.hypot(a, b)
    h = np.degrees(np.arctan2(b, a)) % 360

    w = skin_weight(L, C, h, h_center)
    C2 = C * (1 - (1 - c_scale) * w)

    # 中间调轻提，两端收敛，避免高光再次溢出
    mid = np.exp(-(((L - 62) / 34) ** 2))
    L2 = L + lift * mid * (0.35 + 0.65 * w)
    L2 = np.where(L2 > 96.5, 96.5 - (L2 - 96.5) * 0.35, L2)  # 高光软限幅

    hr = np.radians(h)
    a2, b2 = C2 * np.cos(hr), C2 * np.sin(hr)
    return lab_to_srgb(L2, a2, b2)


def measure(path, face):
    r = sm.analyze(Path(path), face)
    if not r.get("ok"):
        return None
    return {k: r[k] for k in ("L", "a", "b", "C", "h", "ITA", "n_px")}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--target-c", type=float, help="目标彩度 C*，默认按实测降 15%")
    ap.add_argument("--lift", type=float, default=0.7, help="中间调提亮量（L* 单位）")
    args = ap.parse_args()

    src = Path(args.src)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    # 先按 EXIF 转正，后续检测、测量、调色全部在同一坐标系下进行
    im = ImageOps.exif_transpose(Image.open(src)).convert("RGB")
    work = im.copy()
    work.thumbnail((2000, 2000), Image.LANCZOS)
    probe = out_dir / f".{src.stem}-probe.png"
    work.save(probe)

    det = json.loads(subprocess.run([str(sm.DETECTOR), str(probe)], capture_output=True, text=True).stdout)[0]
    faces = det.get("faces") or []
    if not faces:
        probe.unlink(missing_ok=True)
        sys.exit("未检测到人脸")
    face = max(faces, key=lambda x: x["bbox"][2] * x["bbox"][3])

    before = measure(probe, face)
    c_scale = (args.target_c / before["C"]) if args.target_c else 0.85
    print(f"实测肤色  L*{before['L']:.1f}  C*{before['C']:.1f}  h°{before['h']:.1f}  ITA {before['ITA']:.1f}")
    print(f"目标彩度  C* {before['C'] * c_scale:.1f}（缩放 {c_scale:.3f}），色相锁定 {before['h']:.1f}°")

    arr = np.asarray(im, dtype=np.float32) / 255.0
    graded = grade(arr, before["h"], c_scale, args.lift)
    out_img = Image.fromarray((np.clip(graded, 0, 1) * 255).astype(np.uint8))
    out_path = out_dir / f"{src.stem}-肤色锚定.jpg"
    out_img.save(out_path, quality=96, subsampling=0)
    print(f"已输出 {out_path}")

    after_img = out_img.copy()
    after_img.thumbnail((2000, 2000), Image.LANCZOS)
    after_img.save(probe)
    after = measure(probe, face)
    probe.unlink(missing_ok=True)

    if after:
        print("\n指标对比")
        print(f"{'':<8}{'原图':>9}{'锚定后':>9}{'偏移':>9}")
        for key, label in (("L", "L*"), ("C", "C*"), ("h", "h°"), ("ITA", "ITA")):
            print(f"{label:<8}{before[key]:>9.2f}{after[key]:>9.2f}{after[key] - before[key]:>+9.2f}")

    json.dump({"before": before, "after": after}, open(out_dir / f"{src.stem}-指标.json", "w"), ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
