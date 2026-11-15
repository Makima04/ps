"""在人物蒙版内把「皮肤」和「服装/头发」分开，补上脸以外的皮肤（手、肩、腿）。

做法不是通用肤色阈值（白蕾丝、白裙、粉裙边都会误判），而是以**这张图脸部实测的
肤色**为先验，在 Lab 空间做色度距离 + 色相闸门，再以「种子区域」做重建扩张，
因此零碎的蕾丝花边不会被误认为皮肤。

用法（命令行自检）：
    python3 Scripts/skin-split.py <图片> --out-prefix /tmp/x
    # 输出 _skin.png（纯蒙版）与 _overlay.png（绿=皮肤 蓝=服装 红=背景）
"""
import argparse
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageOps

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("sm", HERE / "skin-metrics.py")
sm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sm)

MASKER = HERE / "person-mask"
POSE = HERE / "body-pose"
CLOTH = HERE / "cloth-mask"
CLOTH_MODEL = HERE.parent / "Sources/ColorEngine/Models/ClothSegmentation.mlmodelc"


def cloth_of(img: Image.Image, size):
    """项目自带的服装分割模型：返回「是服装」的布尔图（已还原到 size）。"""
    if not (CLOTH.exists() and CLOTH_MODEL.exists()):
        return None
    tmp, out = Path("/tmp/_cloth.jpg"), Path("/tmp/_cloth.png")
    img.save(tmp, quality=96)
    try:
        subprocess.run([str(CLOTH), str(CLOTH_MODEL), str(out), str(tmp)],
                       capture_output=True, check=True)
        m = Image.open(out).convert("L").resize(size, Image.LANCZOS)
    except Exception:
        return None
    return np.asarray(m) > 127


def label_components(mask: np.ndarray, ds: int = 4):
    """行程法两遍标号，返回 (label 图, 组件数)。不依赖 scipy。"""
    h, w = mask.shape
    hh, ww = h // ds, w // ds
    m = mask[:hh * ds, :ww * ds].reshape(hh, ds, ww, ds).any(axis=(1, 3))

    parent = [0]

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[max(ra, rb)] = min(ra, rb)

    small = np.zeros((hh, ww), dtype=np.int32)
    prev = []                       # 上一行的 (start, end, label)
    nxt = 0
    for y in range(hh):
        row = m[y].astype(np.int8)
        d = np.diff(np.concatenate(([0], row, [0])))
        starts = np.flatnonzero(d == 1)
        ends = np.flatnonzero(d == -1)
        cur = []
        for s, e in zip(starts, ends):
            lab = None
            for ps, pe, pl in prev:
                if s < pe and ps < e:          # 8 邻接近似：区间相交即连通
                    if lab is None:
                        lab = find(pl)
                    else:
                        union(lab, pl)
            if lab is None:
                nxt += 1
                parent.append(nxt)
                lab = nxt
            cur.append((s, e, lab))
            small[y, s:e] = lab
        prev = cur

    # 压平并重编号，避免空号
    flat = np.array([find(i) for i in range(len(parent))], dtype=np.int32)
    uniq = np.unique(flat)
    remap = np.zeros(flat.max() + 1, dtype=np.int32)
    for new, old in enumerate(uniq):
        remap[old] = new
    full = remap[flat[small]]
    full = np.repeat(np.repeat(full, ds, axis=0), ds, axis=1)
    # 下采样时按 ds 取整，边界补回原尺寸
    full = np.pad(full, ((0, max(0, h - full.shape[0])),
                         (0, max(0, w - full.shape[1]))), mode="edge")
    return full, len(uniq) - 1


def limb_zones(pose: dict, w: int, h: int):
    """由关节连成胶囊状「肢体走廊」+ 贴骨的「核心区」。

    走廊用于判断「这块色块大致在一根肢体的范围里」；
    核心区（骨骼线外扩一个刻度、以及腕/踝的关节盘）用于判断「这块色块是不是真的长在肢体上」。
    只走廊是不够的——两腿之间的裙料内衬同样落在走廊里，但它离骨骼很远。
    """
    if not pose:
        return None
    j = pose["joints"]

    def P(name):
        v = j.get(name)
        return None if not v else (v[0] * w, v[1] * h)

    sh_l, sh_r = P("leftShoulder"), P("rightShoulder")
    if not (sh_l and sh_r):
        return None
    sh_w = float(np.hypot(sh_l[0] - sh_r[0], sh_l[1] - sh_r[1]))
    r_arm = max(6.0, 0.34 * sh_w)
    r_leg = max(8.0, 0.46 * sh_w)
    tol = max(4.0, 0.055 * sh_w)      # 贴骨容差：皮肤是包在骨头外面的，余量给小

    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    zone = np.zeros((h, w), dtype=bool)
    core = np.zeros((h, w), dtype=bool)

    def capsule(p0, p1, r, target, grow=0.0):
        vx, vy = p1[0] - p0[0], p1[1] - p0[1]
        L2 = vx * vx + vy * vy
        if L2 < 1.0:
            return
        t = np.clip(((xx - p0[0]) * vx + (yy - p0[1]) * vy) / L2, 0.0, 1.0)
        dx = xx - (p0[0] + t * vx)
        dy = yy - (p0[1] + t * vy)
        target[:] |= (dx * dx + dy * dy) <= r * r

    def disc(p, r, target):
        target[:] |= ((xx - p[0]) ** 2 + (yy - p[1]) ** 2) <= r * r

    for side in ("left", "right"):
        s, e = P(f"{side}Shoulder"), P(f"{side}Elbow")
        wr = P(f"{side}Wrist")
        hip, knee, ank = P(f"{side}Hip"), P(f"{side}Knee"), P(f"{side}Ankle")
        for p0, p1, r in ((s, e, r_arm), (e, wr, r_arm),
                          (hip, knee, r_leg), (knee, ank, r_leg)):
            if p0 and p1:
                capsule(p0, p1, r, zone)
                capsule(p0, p1, tol, core)
        if wr:
            disc(wr, 1.45 * r_arm, zone)     # 手掌比前臂宽
            disc(wr, 1.55 * r_arm, core)     # 手是判定「这块皮肤长在肢体上」的锚点
        if ank:
            disc(ank, 0.80 * r_leg, zone)
            # 踝部核心盘要小：袜套上的蝴蝶结就贴在踝关节附近，盘一大就会把它
            # 当成「长在肢体上的皮肤」而保护起来。脚本来就多被鞋袜覆盖，宁小勿大。
            disc(ank, 0.50 * r_leg, core)
    return {"zone": zone, "core": core, "shoulder_w": sh_w}


def pose_of(img: Image.Image):
    if not POSE.exists():
        return None
    tmp = Path("/tmp/_pose.jpg")
    img.save(tmp, quality=96)
    try:
        out = subprocess.run([str(POSE), str(tmp)], capture_output=True,
                             text=True).stdout
        det = json.loads(out)[0]
    except Exception:
        return None
    poses = det.get("poses") or []
    return max(poses, key=lambda p: p["confidence"]) if poses else None


def box_blur(x, r):
    """积分图均值模糊，用于软形态学。"""
    if r < 1:
        return x
    p = np.pad(x, r, mode="edge")
    c = np.cumsum(np.cumsum(p, axis=0), axis=1)
    c = np.pad(c, ((1, 0), (1, 0)))
    k = 2 * r + 1
    H, W = x.shape
    return (c[k:k + H, k:k + W] - c[0:H, k:k + W]
            - c[k:k + H, 0:W] + c[0:H, 0:W]) / (k * k)


def erode(m, r):
    return box_blur(m.astype(np.float32), r) > 0.995


def dilate(m, r):
    return box_blur(m.astype(np.float32), r) > 0.005


def opening(m, r):
    return dilate(erode(m, r), r)


def closing(m, r):
    return erode(dilate(m, r), r)


def compute(path: Path, long_edge: int = 1400,
            core: float = 6.0, soft: float = 10.0, hue_width: float = 22.0,
            use_pose: bool = True, use_cloth: bool = False,
            body_hue_gain: float = 1.0) -> dict:
    """返回四层蒙版与 Lab 体数据。皮肤层已排除服装、头发、蕾丝与唇色。"""
    im = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
    probe = Path("/tmp/_ss.jpg")
    im.save(probe, quality=96)

    det = json.loads(subprocess.run([str(sm.DETECTOR), str(probe)],
                                    capture_output=True, text=True).stdout)[0]
    faces = det.get("faces") or []
    if not faces:
        raise SystemExit("未检测到人脸")
    face = max(faces, key=lambda x: x["bbox"][2] * x["bbox"][3])
    ref = sm.analyze(probe, face, half=False)
    if not ref.get("ok"):
        raise SystemExit(f"肤色测量失败：{ref.get('reason')}")

    work = im.copy()
    work.thumbnail((long_edge, long_edge), Image.LANCZOS)
    w, h = work.size
    tmp, msk = Path("/tmp/_ss2.jpg"), Path("/tmp/_ss2.png")
    work.save(tmp, quality=96)
    subprocess.run([str(MASKER), str(tmp), str(msk)], capture_output=True)
    person = np.asarray(Image.open(msk).convert("L").resize((w, h),
                        Image.LANCZOS)) > 110

    arr = np.asarray(work, dtype=np.float32) / 255.0
    L, a, b = sm.to_lab(arr)
    C = np.hypot(a, b)
    hue = np.degrees(np.arctan2(b, a)) % 360

    # 1) 色度距离：a*/b* 是肤色身份，权重高；L* 随光线变化，权重低
    da, db = a - ref["a"], b - ref["b"]
    dL = (L - ref["L"]) / 2.2
    dist = np.sqrt(da ** 2 + db ** 2 + dL ** 2 * 0.55)

    # 2) 色相闸门：粉色蕾丝、洋红裙边与肤色的色相差 40° 以上，必须排除
    dh = np.abs(hue - ref["h"])
    dh = np.minimum(dh, 360 - dh)
    hue_ok = np.exp(-((dh / hue_width) ** 2))
    chromatic = C > 9.0                 # 白蕾丝/白裙 C* 极低，天然出局

    cand = (dist < soft) & (hue_ok > 0.35) & chromatic & person
    core_mask = (dist < core) & (hue_ok > 0.5) & chromatic & person

    # 3) 种子 + 重建：只保留成片的区域作种子（脸、手、腿），
    #    袜子上的粉丝带这类小斑块在开运算里被削掉，之后也无法通过连通性长回来
    seeds = opening(cand | core_mask, 6)
    skin = seeds
    for _ in range(10):
        skin = dilate(skin, 2) & cand
    skin = closing(skin, 3) & person

    # 4) 皮肤再分面部 / 肢体：同一张照片里，脸上的妆与受光让两者色度不同
    bx, by, bw, bh = face["bbox"]
    face_zone = np.zeros((h, w), dtype=bool)
    y0, y1 = int((by - 0.45 * bh) * h), int((by + 1.55 * bh) * h)
    x0, x1 = int((bx - 0.35 * bw) * w), int((bx + 1.35 * bw) * w)
    face_zone[max(0, y0):max(0, y1), max(0, x0):max(0, x1)] = True

    # 5) 脸部单独建模：腮红会把脸颊的彩度顶到远高于参考值，只靠色度距离会把
    #    最该修的两颊挖空。脸部改用「多边形/定向椭圆 + 排除头发」为主、配色判据为辅。
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    face_ellipse = None
    contour = face.get("contour")
    if contour and len(contour) >= 8:
        # Vision 的 faceContour 只给下颌到鬓角这一段，缺额头。
        # 取两端点连成弦，沿弦的法向向上补出额头，再围成闭合多边形。
        pts = np.array([(p[0] * w, p[1] * h) for p in contour], dtype=np.float32)
        p0, p1 = pts[0], pts[-1]
        chord = p1 - p0
        clen = float(np.hypot(*chord)) or 1.0
        n = np.array([chord[1], -chord[0]], dtype=np.float32) / clen
        # n 指向脸内（向上）：用双眼中点判断方向
        mo = face.get("mouth")
        if mo:
            mid = (p0 + p1) / 2
            mouth_px = np.array([mo[0] * w, mo[1] * h], dtype=np.float32)
            if np.dot(mouth_px - mid, n) > 0:
                n = -n
        lift = 0.62 * clen
        poly = [tuple(p) for p in pts]
        poly.append(tuple(p1 + n * lift))
        poly.append(tuple((p0 + p1) / 2 + n * lift * 1.06))
        poly.append(tuple(p0 + n * lift))
        pm = Image.new("L", (w, h), 0)
        ImageDraw.Draw(pm).polygon([(float(a), float(b)) for a, b in poly], fill=255)
        cand_poly = np.asarray(pm) > 127
        # 合理性校验：轮廓点若只覆盖半侧下颌，闭合成多边形后面积会远小于人脸框，
        # 这时宁可退回椭圆，也不要用一个畸形的多边形去切脸。
        bbox_area = max(1.0, bw * w * bh * h)
        if cand_poly.sum() >= 0.45 * bbox_area:
            face_ellipse = cand_poly
    if face_ellipse is None:
        pl, pr, mo = face.get("leftPupil"), face.get("rightPupil"), face.get("mouth")
        if pl and pr and mo:
            ex = [(pl[0] + pr[0]) / 2 * w, (pl[1] + pr[1]) / 2 * h]
            mx, my = mo[0] * w, mo[1] * h
            vx, vy = mx - ex[0], my - ex[1]
            d_em = float(np.hypot(vx, vy)) or 1.0
            ux, uy = vx / d_em, vy / d_em            # 沿脸向下
            d_eye = float(np.hypot((pl[0] - pr[0]) * w, (pl[1] - pr[1]) * h)) or d_em
            cx_f = ex[0] + ux * d_em * 0.55
            cy_f = ex[1] + uy * d_em * 0.55
            du = (xx - cx_f) * ux + (yy - cy_f) * uy
            dv = -(xx - cx_f) * uy + (yy - cy_f) * ux
            face_ellipse = ((du / (d_em * 1.45)) ** 2
                            + (dv / (d_eye * 1.05)) ** 2) <= 1.0
        else:
            cx_f, cy_f = (bx + bw / 2) * w, (by + 0.55 * bh) * h
            face_ellipse = (((xx - cx_f) / (0.55 * bw * w)) ** 2
                            + ((yy - cy_f) / (0.78 * bh * h)) ** 2) <= 1.0

    # 脸部专属区域：多边形/椭圆 再并上略微放宽的人脸框。
    # 否则脸颊边缘、下巴这些落在多边形外的皮肤会被判成「肢体」，
    # 于是同一张脸上出现两层，后续分面/分身的补偿就会互相打架。
    box_pad = 0.12
    face_box = np.zeros((h, w), dtype=bool)
    face_box[max(0, int((by - box_pad * bh) * h)):min(h, int((by + (1 + box_pad) * bh) * h)),
             max(0, int((bx - box_pad * bw) * w)):min(w, int((bx + (1 + box_pad) * bw) * w))] = True
    face_region = face_ellipse | face_box

    not_hair = L > (ref["L"] - 25.0)          # 头发比肤色暗一个量级，用亮度排除
    blush_ok = (dist < soft * 1.40) & (hue_ok > 0.25)
    face_cand = person & face_region & not_hair & (C > 7.0) & blush_ok
    face_skin = closing(face_cand, 5) & person & face_region
    # 眼部与唇部仍会被挖空，用一次大半径闭运算补齐，再回到脸区内
    face_skin = closing(face_skin, 6) & person & face_region

    # 6) 肢体皮肤：色相窗口由**这张脸自身的色相离散度**决定，不能写死。
    #    写死会有两难：窗口宽 → 粉色裙料被吃进（663 裙内衬 h°28.3 vs 皮肤 35.4，只差 7°）；
    #    窗口窄 → 别的光线下真实手臂被判掉（参考 08 的手臂在阴影里偏 7°，一样被砍）。
    #    正确做法是先量这张脸允许多少波动，再按比例给肢体留余量。
    r_h = np.radians(hue[face_skin])
    if face_skin.sum() > 400:
        R = float(np.hypot(np.cos(r_h).mean(), np.sin(r_h).mean()))
        circ_std = float(np.degrees(np.sqrt(max(0.0, -2.0 * np.log(max(R, 1e-6))))))
    else:
        circ_std = 6.0
    hue_w = float(np.clip(circ_std * body_hue_gain, 4.5, 15.0))

    dh_b = np.abs(hue - ref["h"])
    dh_b = np.minimum(dh_b, 360 - dh_b)
    body_hue_ok = np.exp(-(dh_b / hue_w) ** 2) > 0.42
    body_cand = ((dist < soft) & body_hue_ok & (C > 9.0) & (C < 52.0)
                 & person & ~face_region)

    pose = pose_of(work) if use_pose else None
    lz = limb_zones(pose, w, h)
    zone = lz["zone"] if lz else None
    bone_core = lz["core"] if lz else None
    sh_w = lz["shoulder_w"] if lz else 0.0

    # 种子 + 重建：只保留成片的区域作种子，零碎花边长不回来
    body_color = opening(body_cand, 5)
    for _ in range(8):
        body_color = dilate(body_color, 2) & body_cand
    body_color = closing(body_color, 2) & person & ~face_region
    body_skin = body_color
    rejected = 0
    if zone is not None:
        lab, n = label_components(body_color, ds=4)
        keep = np.zeros(int(lab.max()) + 1, dtype=bool)
        for i in range(1, int(lab.max()) + 1):
            sel = lab == i
            area = int(sel.sum())
            if area < 30:
                continue
            # 两个条件同时满足才保留：
            # ① 大半落在肢体走廊内（排除躯干上的大色块，如裙身）
            # ② 碰到骨骼核心区（排除两腿之间的裙料内衬、袜子上的粉蝴蝶结——
            #    它们同样在走廊里，但离骨骼很远）
            inside = float((sel & zone).sum()) / area
            touches = bool((sel & bone_core).any())
            if inside >= 0.45 and touches:
                keep[i] = True
            else:
                rejected += 1
        body_skin = keep[lab] & body_color

    # 7) 高光补洞：手背、额头反光处 L* 冲到 95、C* 掉到 4，彩度判据必然把它排除，
    #    于是整只手被挖掉一半。做法是「亮 + 低彩度 + 紧贴已确认皮肤」，而不是放宽彩度阈值
    #    （放宽会把白蕾丝、白裙一起放进来）。
    hl_cand = (person & ~face_region & (C < 9.0) & (L > 84.0))
    hl_fill = hl_cand & dilate(body_skin, max(4, int(0.012 * max(w, h))))
    hl_fill = closing(hl_fill | body_skin, 3) & person & ~face_region
    # 补回来的部分仍要落在肢体走廊附近，避免顺着白袜、白裙爬上去
    if zone is not None:
        hl_fill &= dilate(zone, max(4, int(0.010 * max(w, h))))
    body_skin = (body_skin | hl_fill) & person & ~face_region

    # 8) 语义服装层：粉色裙料与肤色在 Lab 上几乎重合（663 粉裙 L*66 C*28 h°38.6
    #    vs 肤色 L*72.7 C*28 h°37），纯配色判据必然把裙料、裙内衬、袜套上的粉蝴蝶结
    #    一起算作皮肤。几何只能排掉离骨骼远的块，贴在骨边的那些必须靠语义。
    #    这里用项目已有的 ClothSegmentation 模型作第三个独立信号。
    cloth_up = cloth_of(work, (w, h)) if use_cloth else None
    cloth_hit = 0
    if cloth_up is not None:
        hit = body_skin & cloth_up
        cloth_hit = int(hit.sum())
        # 只减掉确定是服装的部分；模型在边缘会给软值，先腐蚀一像素避免啃掉皮肤边界
        protected = body_skin & bone_core & (dist < core)
        body_skin = ((body_skin & ~erode(cloth_up, 1)) | protected)

    skin = (face_skin | body_skin) & person

    return {
        "image": work, "L": L, "a": a, "b": b, "C": C,
        "ref": ref, "face": face, "pose": pose, "zone": zone,
        "cloth_model": cloth_up, "cloth_removed_px": cloth_hit,
        "shoulder_w": sh_w, "rejected_blocks": rejected,
        "hue_std": circ_std, "hue_width": hue_w,
        "skin": skin, "skin_face": face_skin, "skin_body": body_skin,
        "cloth": person & ~skin, "bg": ~person,
    }


def layer_stats(d: dict, mask: np.ndarray, min_px: int = 300) -> dict:
    if mask.sum() < min_px:
        return {"ok": False, "frac": float(mask.mean())}
    L, a, b = d["L"][mask], d["a"][mask], d["b"][mask]
    C = np.hypot(a, b)
    h = np.degrees(np.arctan2(b, a)) % 360
    use = C > 6
    hh = None
    if use.sum() > 50:
        r = np.radians(h[use])
        hh = float(np.degrees(np.arctan2(np.sin(r).mean(), np.cos(r).mean())) % 360)
    return {
        "ok": True, "frac": float(mask.mean()),
        "L": float(np.median(L)), "C": float(np.median(C)),
        "a": float(np.median(a)), "b": float(np.median(b)), "h": hh,
    }


def hue_gap(x, y):
    d = abs(x - y) % 360
    return float(min(d, 360 - d))


def relations(stats: dict) -> dict:
    sk = stats.get("skin_face") if stats.get("skin_face", {}).get("ok") else stats.get("skin_body", {})
    cl, ba = stats.get("cloth", {}), stats.get("bg", {})
    rel = {}
    if sk.get("ok") and ba.get("ok"):
        rel["dL_skin_bg"] = sk["L"] - ba["L"]
        rel["C_skin_over_bg"] = sk["C"] / max(ba["C"], 0.5)
        rel["dh_skin_bg"] = (hue_gap(sk["h"], ba["h"])
                             if sk.get("h") is not None and ba.get("h") is not None else None)
        # 色相距离 × 背景彩度：背景近中性时，色相分离在实际观感中不存在
        rel["visible_sep"] = (rel["dh_skin_bg"] * ba["C"] / 10.0
                              if rel["dh_skin_bg"] is not None else 0.0)
    if sk.get("ok") and cl.get("ok"):
        rel["C_skin_over_cloth"] = sk["C"] / max(cl["C"], 0.5)
        rel["dh_skin_cloth"] = (hue_gap(sk["h"], cl["h"])
                                if sk.get("h") is not None and cl.get("h") is not None else None)
    return rel


def verdict(rel: dict, stats: dict) -> list:
    ba = stats.get("bg", {})
    notes = []
    if not ba.get("ok"):
        return ["背景层缺失"]
    if ba["C"] < 7:
        notes.append(f"背景近乎无色相（C*{ba['C']:.1f}），色相分离无解")
    ratio = rel.get("C_skin_over_bg")
    if ratio is not None and ratio > 2.5:
        notes.append(f"皮肤比背景艳 {ratio:.1f} 倍，色斑会被放大")
    elif ratio is not None and ratio < 0.55:
        notes.append(f"皮肤彩度低于背景（{ratio:.2f} 倍），人被环境压住")
    sep = rel.get("visible_sep", 0)
    if sep < 20:
        notes.append(f"可见色相分离仅 {sep:.0f}，边界易混")
    return notes or ["三层关系健康"]


def overlay(d: dict) -> Image.Image:
    ov = np.asarray(d["image"], dtype=np.float32) / 255.0
    # 四种着色必须彼此远离：面部与肢体同为皮肤却不该混视，服装必须区别于两者。
    # 面部=亮绿，肢体=青色，服装=蓝紫，背景=红。
    tint = {"skin_face": (0.15, 0.95, 0.20), "skin_body": (0.00, 0.80, 0.80),
            "cloth": (0.40, 0.20, 0.95), "bg": (0.95, 0.15, 0.20)}
    for name, c in tint.items():
        m = d[name]
        ov[m] = ov[m] * 0.35 + np.array(c, dtype=np.float32) * 0.65
    return Image.fromarray((np.clip(ov, 0, 1) * 255).astype(np.uint8))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("--out-prefix")
    args = ap.parse_args()

    d = compute(Path(args.src))
    stats = {k: layer_stats(d, d[k]) for k in ("skin_face", "skin_body", "cloth", "bg")}
    rel = relations(stats)
    print(f"{Path(args.src).name}  参考肤色 L*{d['ref']['L']:.1f} "
          f"a*{d['ref']['a']:.1f} b*{d['ref']['b']:.1f} h°{d['ref']['h']:.1f}")
    for k, label in (("skin_face", "面部皮肤"), ("skin_body", "肢体皮肤"),
                     ("cloth", "服装"), ("bg", "背景")):
        s = stats[k]
        if not s.get("ok"):
            print(f"  {label}  面积不足")
            continue
        hs = f"{s['h']:5.1f}" if s["h"] is not None else "  n/a"
        print(f"  {label}  占比 {s['frac'] * 100:5.1f}%   L*{s['L']:5.1f}  "
              f"C*{s['C']:5.1f}  h°{hs}")
    if rel.get("C_skin_over_bg") is not None:
        print(f"  皮肤/背景彩度 {rel['C_skin_over_bg']:.2f}   "
              f"色相差 {rel['dh_skin_bg']:.1f}°   可见分离 {rel['visible_sep']:.0f}"
              if rel.get("dh_skin_bg") is not None else "")
    print("  判定：" + "；".join(verdict(rel, stats)))

    if args.out_prefix:
        prefix = Path(args.out_prefix)
        overlay(d).save(f"{prefix}_overlay.png")
        Image.fromarray((d["skin"] * 255).astype(np.uint8)).save(f"{prefix}_skin.png")
        print(f"  已输出 {prefix}_overlay.png / _skin.png")


if __name__ == "__main__":
    main()
