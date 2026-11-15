#!/usr/bin/env python3
"""人像精修级调色：在肤色锚定之上补上结构与质感。

与 v1 的区别——v1 只做逐像素颜色运算，这张图真正缺的是空间域的四件事：
  1. 频率分离：只压低频色块的彩度，保留毛孔与纹理
  2. 面部塑形：按关键点提升 T 区与颧骨、压暗下颌与颞侧
  3. 局部锐度：发丝、睫毛、蕾丝加锐，皮肤不加
  4. 通透度：中间调拉反差、白位收紧、外圈轻微压暗分离主体

用法：
  python3 Scripts/portrait-grade.py 原图.jpg --out-dir 目录 [--scale 1.0]
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


# ---------- 基础工具 ----------

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


def box1d(a, r, axis):
    if r < 1:
        return a
    a = np.moveaxis(a, axis, 0)
    pad = np.concatenate([np.repeat(a[:1], r + 1, 0), a, np.repeat(a[-1:], r, 0)], 0)
    cs = np.cumsum(pad, axis=0, dtype=np.float32)
    out = (cs[2 * r + 1:] - cs[:-(2 * r + 1)]) / (2 * r + 1)
    return np.moveaxis(out, 0, axis)


def blur(a, r, passes=3):
    """三次盒式模糊近似高斯。"""
    for _ in range(passes):
        a = box1d(box1d(a, r, 0), r, 1)
    return a


def smoothstep(x, lo, hi):
    t = np.clip((x - lo) / max(hi - lo, 1e-6), 0, 1)
    return t * t * (3 - 2 * t)


def gauss2d(shape, cx, cy, sx, sy):
    h, w = shape
    y = np.arange(h, dtype=np.float32)[:, None]
    x = np.arange(w, dtype=np.float32)[None, :]
    return np.exp(-(((x - cx) / sx) ** 2 + ((y - cy) / sy) ** 2))


def person_mask(im, work_dir):
    """调用 Vision 人物分割，返回与 im 同尺寸的柔化蒙版（float 0..1）。"""
    from PIL import ImageDraw

    tmp_src = work_dir / "._pm-src.jpg"
    tmp_mask = work_dir / "._pm-mask.png"
    im.save(tmp_src, quality=95)
    r = subprocess.run([str(HERE / "person-mask"), str(tmp_src), str(tmp_mask)],
                       capture_output=True, text=True)
    tmp_src.unlink(missing_ok=True)
    if not tmp_mask.exists():
        print(f"人物分割失败：{r.stderr.strip()}")
        return None

    m = Image.open(tmp_mask).convert("L").resize(im.size, Image.LANCZOS)
    arr = (np.asarray(m) > 127).astype(np.uint8)

    # 填掉主体内部被误判的孔洞，避免背景虚化渗进来
    inv = Image.fromarray(((1 - arr) * 255).astype(np.uint8))
    canv = inv.copy()
    w, h = canv.size
    for pt in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)):
        try:
            ImageDraw.floodfill(canv, pt, 128, thresh=8)
        except Exception:
            pass
    outside = np.asarray(canv) == 128
    holes = (np.asarray(inv) > 127) & ~outside
    arr = (arr.astype(bool) | holes).astype(np.float32)
    tmp_mask.unlink(missing_ok=True)

    # 羽化时刻意把 50% 交点向外推（膨胀），否则虚化的背景会渗到主体边缘形成亮光晕
    soft = blur(arr, 5, passes=2)
    return smoothstep(soft, 0.16, 0.46)


def apply_bokeh(rgb, mask, d, dim, desat, r_mult, cool=0.0):
    r = max(6, int(d * r_mult))
    bg = np.stack([blur(rgb[..., i], r, passes=3) for i in range(3)], axis=-1)
    if desat > 0 or dim > 0 or cool != 0:
        L, a, b = sm.to_lab(bg)
        a, b = a * (1 - desat), b * (1 - desat) - cool
        L = L * (1 - dim)
        bg = lab_to_srgb(L, a, b)
    w = mask[..., None]
    return rgb * w + bg * (1 - w)


# ---------- 各步骤 ----------

def skin_soft(L, C, h, h_center):
    dh = np.abs(h - h_center)
    dh = np.minimum(dh, 360 - dh)
    w = np.exp(-((dh / 26.0) ** 2))
    w *= smoothstep(C, 3, 12) * (1 - smoothstep(C, 52, 70))
    w *= smoothstep(L, 15, 30) * (1 - smoothstep(L, 90, 98))
    return w


def face_axes(face, W, H):
    """返回眼部中点、单位向量 u（沿双眼）与 n（指向下巴）、眼距 d。"""
    lp, rp, m = face.get("leftPupil"), face.get("rightPupil"), face.get("mouth")
    if not (lp and rp and m):
        bx, by, bw, bh = face["bbox"]
        eye = np.array([(bx + bw / 2) * W, (by + 0.42 * bh) * H], dtype=np.float32)
        d = bw * W * 1.4
        return eye, np.array([1.0, 0.0]), np.array([0.0, 1.0]), d
    Le = np.array([lp[0] * W, lp[1] * H], dtype=np.float32)
    Re = np.array([rp[0] * W, rp[1] * H], dtype=np.float32)
    M = np.array([m[0] * W, m[1] * H], dtype=np.float32)
    eye = (Le + Re) / 2
    d = float(np.linalg.norm(Re - Le))
    u = (Re - Le) / (np.linalg.norm(Re - Le) + 1e-6)
    v = M - eye
    n = v / (np.linalg.norm(v) + 1e-6)
    return eye, u, n, d


def shaping_field(Lshape, eye, u, n, d):
    """塑形光场：正值提亮（T 区、颧骨），负值压暗（下颌、颞侧）。"""
    H, W = Lshape
    def at(a_down, a_side):
        return eye + n * (a_down * d) + u * (a_side * d)

    field = np.zeros(Lshape, dtype=np.float32)

    # T 区：鼻梁到眉心
    for down, amp, s in ((0.35, 2.6, 0.42), (0.75, 2.0, 0.32)):
        p = at(down, 0.0)
        field += amp * gauss2d(Lshape, p[0], p[1], s * d, s * d)
    # 颧骨
    for side in (-0.62, 0.62):
        p = at(0.80, side)
        field += 2.2 * gauss2d(Lshape, p[0], p[1], 0.40 * d, 0.38 * d)
    # 下颌两侧压暗
    for side in (-0.70, 0.70):
        p = at(1.55, side)
        field -= 3.2 * gauss2d(Lshape, p[0], p[1], 0.55 * d, 0.50 * d)
    # 颞侧压暗
    for side in (-1.05, 1.05):
        p = at(0.15, side)
        field -= 2.2 * gauss2d(Lshape, p[0], p[1], 0.45 * d, 0.55 * d)

    # 限制在面部椭圆内，避免渗到背景
    yy = np.arange(H, dtype=np.float32)[:, None]
    xx = np.arange(W, dtype=np.float32)[None, :]
    rel_x = (xx - eye[0]) / (1.35 * d)
    rel_y = (yy - eye[1]) / (1.9 * d)
    limit = 1 - smoothstep((rel_x**2 + rel_y**2) ** 0.5, 0.75, 1.05)
    return field * limit


def grade(arr, face, W, H, opts):
    L, a, b = sm.to_lab(arr)
    C = np.hypot(a, b)
    h = np.degrees(np.arctan2(b, a)) % 360
    eye, u, n, d = face_axes(face, W, H)

    # 肤色取样（脸颊区）确定色相锚点
    m = sm.cheek_mask(face, W, H)
    if m.sum() > 500:
        h_center = float(np.median(h[m]))
        c_now = float(np.median(C[m]))
    else:
        h_center, c_now = 36.0, 30.0

    # 1) 频率分离：只压低频色块的彩度，纹理保留
    r_fs = max(4, int(d * 0.055))
    low_a, low_b = blur(a, r_fs), blur(b, r_fs)
    w_skin = blur(skin_soft(L, C, h, h_center), max(3, r_fs // 2), passes=2)
    k = opts["c_scale"]
    scale_low = 1 - (1 - k) * np.clip(w_skin * 1.4, 0, 1)
    a = low_a * scale_low + (a - low_a)
    b = low_b * scale_low + (b - low_b)

    # 2) 面部塑形
    L = L + opts["shape"] * shaping_field(L.shape, eye, u, n, d)

    # 3) 局部锐度：皮肤减半，发丝/蕾丝足量
    detail = L - blur(L, max(1, int(d * 0.006)), passes=2)
    sharp_w = 1 - 0.75 * np.clip(w_skin * 1.3, 0, 1)
    L = L + opts["sharpen"] * detail * sharp_w

    # 4) 通透度：中间调拉反差 + 白位收紧
    mid = np.exp(-(((L - 52) / 40) ** 2))
    L = L + opts["contrast"] * (L - 50) * mid
    L = np.where(L > 96.0, 96.0 - (L - 96.0) * 0.30, L)
    L = np.clip(L, 0, 100)

    # 5) 外圈压暗，分离主体
    yy = np.arange(H, dtype=np.float32)[:, None]
    xx = np.arange(W, dtype=np.float32)[None, :]
    rr = np.sqrt(((xx - eye[0]) / (W * 0.62)) ** 2 + ((yy - eye[1]) / (H * 0.58)) ** 2)
    L = L * (1 - opts["vignette"] * smoothstep(rr, 0.55, 1.45))

    return lab_to_srgb(L, a, b), {"h_center": h_center, "c_before": c_now, "d": d}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--scale", type=float, default=1.0, help="输出缩放，1.0 为原始尺寸")
    ap.add_argument("--target-c", type=float, default=30.0)
    ap.add_argument("--shape", type=float, default=1.0, help="塑形强度倍率")
    ap.add_argument("--sharpen", type=float, default=0.55)
    ap.add_argument("--contrast", type=float, default=0.05)
    ap.add_argument("--vignette", type=float, default=0.10)
    ap.add_argument("--bokeh", type=float, default=0.0, help="背景虚化强度，按眼距倍数，0 关闭")
    ap.add_argument("--bg-dim", type=float, default=0.0, help="背景压暗比例 0-1")
    ap.add_argument("--bg-desat", type=float, default=0.0, help="背景降饱和比例 0-1")
    ap.add_argument("--bg-cool", type=float, default=0.0, help="背景推冷的 b* 偏移量")
    ap.add_argument("--film-blacks", type=float, default=0.0, help="抬黑位，制造胶片雾感")
    args = ap.parse_args()

    src = Path(args.src)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    im = ImageOps.exif_transpose(Image.open(src)).convert("RGB")
    if args.scale != 1.0:
        im = im.resize((int(im.width * args.scale), int(im.height * args.scale)), Image.LANCZOS)
    W, H = im.size

    probe = out_dir / f".{src.stem}-probe.png"
    t = im.copy()
    t.thumbnail((2000, 2000), Image.LANCZOS)
    t.save(probe)
    det = json.loads(subprocess.run([str(sm.DETECTOR), str(probe)], capture_output=True, text=True).stdout)[0]
    faces = det.get("faces") or []
    if not faces:
        probe.unlink(missing_ok=True)
        sys.exit("未检测到人脸")
    face = max(faces, key=lambda x: x["bbox"][2] * x["bbox"][3])

    # 用同一尺度的探针图测原值，避免缩放后坐标错位
    before = sm.analyze(probe, face)

    arr = np.asarray(im, dtype=np.float32) / 255.0
    k = args.target_c / max(before["C"], 1e-3) if before.get("ok") else 0.85
    opts = dict(c_scale=k, shape=args.shape, sharpen=args.sharpen,
                contrast=args.contrast, vignette=args.vignette)
    out, info = grade(arr, face, W, H, opts)

    if args.bokeh > 0:
        pm = person_mask(Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8)), out_dir)
        if pm is not None:
            out = apply_bokeh(out, pm, info["d"], args.bg_dim, args.bg_desat,
                              args.bokeh, args.bg_cool)
            print(f"背景虚化 半径 {int(info['d'] * args.bokeh)}px  压暗 {args.bg_dim:.2f}  "
                  f"降饱和 {args.bg_desat:.2f}  推冷 {args.bg_cool:.1f}")

    if args.film_blacks > 0:
        L, a, b = sm.to_lab(out)
        L = L + args.film_blacks * (1 - smoothstep(L, 0, 40))
        out = lab_to_srgb(np.clip(L, 0, 100), a, b)

    out_path = out_dir / f"{src.stem}-精修.jpg"
    out_img = Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8))
    out_img.save(out_path, quality=96, subsampling=0)
    print(f"肤色锚点 h° {info['h_center']:.1f}  彩度 {info['c_before']:.1f} → 目标 {args.target_c:.1f}")
    print(f"眼距 {info['d']:.0f}px  输出 {out_path}")

    # 输出图在同一尺度下复测
    after_img = out_img.copy()
    after_img.thumbnail((2000, 2000), Image.LANCZOS)
    after_img.save(probe)
    after = sm.analyze(probe, face)
    probe.unlink(missing_ok=True)
    if before.get("ok") and after:
        print(f"\n{'':<6}{'原图':>9}{'精修':>9}{'偏移':>9}")
        for key, lab in (("L", "L*"), ("C", "C*"), ("h", "h°"), ("ITA", "ITA")):
            print(f"{lab:<6}{before[key]:>9.2f}{after[key]:>9.2f}{after[key] - before[key]:>+9.2f}")
        json.dump({"before": before, "after": after}, open(out_dir / f"{src.stem}-指标.json", "w"),
                  ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
