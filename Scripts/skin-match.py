"""把一张照片的肤色参数对齐到参考集，用于检验"参数能追回多少观感"。

只动肤色区域（色相锁定），不改构图、不改背景、不加虚化。
用法：
    python3 Scripts/skin-match.py <原图> --out <输出.jpg> \
        --target-c 15 --target-l 79.5
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


M_XYZ2RGB = np.linalg.inv(sm.M_RGB2XYZ)


def lab_to_srgb(L, a, b):
    fy = (L + 16) / 116
    fx = fy + a / 500
    fz = fy - b / 200
    delta = 6.0 / 29.0
    f = np.stack([fx, fy, fz], axis=-1)
    t = np.where(f > delta, f**3, 3 * delta**2 * (f - 4.0 / 29.0))
    lin = np.clip(t * sm.WHITE_D65 @ M_XYZ2RGB.T, 0, 1)
    srgb = np.where(lin <= 0.0031308, lin * 12.92, 1.055 * lin ** (1 / 2.4) - 0.055)
    return np.clip(srgb, 0, 1)


def smoothstep(x, e0, e1):
    t = np.clip((x - e0) / (e1 - e0 + 1e-6), 0, 1)
    return t * t * (3 - 2 * t)


def skin_weight(L, C, h, h_center, h_width=30.0):
    dh = np.abs(h - h_center)
    dh = np.minimum(dh, 360 - dh)
    w_h = np.exp(-((dh / h_width) ** 2))
    w_c = smoothstep(C, 2.0, 9.0) * (1 - smoothstep(C, 46, 64))
    w_l = smoothstep(L, 12, 26) * (1 - smoothstep(L, 90, 99))
    return w_h * w_c * w_l


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("--out", required=True)
    ap.add_argument("--target-c", type=float, required=True)
    ap.add_argument("--target-l", type=float, required=True)
    ap.add_argument("--force", type=float, default=1.0, help="权重整体强度 0-1")
    args = ap.parse_args()

    src = Path(args.src)
    im = ImageOps.exif_transpose(Image.open(src)).convert("RGB")
    W, H = im.size

    probe = Path("/tmp/_sm.jpg")
    im.save(probe, quality=96)
    det = json.loads(subprocess.run([str(sm.DETECTOR), str(probe)],
                                    capture_output=True, text=True).stdout)[0]
    faces = det.get("faces") or []
    if not faces:
        sys.exit("未检测到人脸")
    face = max(faces, key=lambda x: x["bbox"][2] * x["bbox"][3])
    before = sm.analyze(probe, face, half=False)
    if not before.get("ok"):
        sys.exit(f"肤色测量失败：{before.get('reason')}")

    h_c = before["h"]
    arr = np.asarray(im, dtype=np.float32) / 255.0
    L, a, b = sm.to_lab(arr)
    C = np.hypot(a, b)
    h = np.degrees(np.arctan2(b, a)) % 360

    w = skin_weight(L, C, h, h_c) * args.force
    # 彩度：按实测中位数确定缩放比
    c_scale = args.target_c / max(before["C"], 1e-3)
    C2 = C * (1 + w * (c_scale - 1))
    # 亮度：以实测中位数为锚整体平移，高光处渐弱
    dL = args.target_l - before["L"]
    hi_protect = 1 - smoothstep(L, 88, 98)
    L2 = L + w * dL * hi_protect
    L2 = np.where(L2 > 97.5, 97.5 - (L2 - 97.5) * 0.3, L2)

    a2, b2 = C2 * np.cos(np.radians(h)), C2 * np.sin(np.radians(h))
    out = lab_to_srgb(L2, a2, b2)

    Image.fromarray((out * 255).astype(np.uint8)).save(
        args.out, quality=96, subsampling=0, icc_profile=None)

    after = dict(before)
    m = sm.cheek_mask(face, W, H)
    keep = m
    Lf, af, bf = L2[keep], a2[keep], b2[keep]
    Cf = np.hypot(af, bf)
    print(f"肤色 C* {before['C']:.1f} → {np.median(Cf):.1f}  "
          f"L* {before['L']:.1f} → {np.median(Lf):.1f}  "
          f"h° 锁定 {h_c:.1f}")
    print(f"输出 {args.out}")


if __name__ == "__main__":
    main()
