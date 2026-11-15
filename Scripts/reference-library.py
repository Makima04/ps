#!/usr/bin/env python3
"""Archive browser-downloaded photo sets by post, then measure their colour styles.

Web images are copied byte-for-byte. Features/masks/previews live separately.
The ingest record contains the first and last downloaded filename and expected
count; filesystem creation order is used only after these boundaries and the
count have been checked. Ambiguous batches fail instead of guessing membership.
"""
import argparse
import hashlib
import io
import json
import re
import shutil
import subprocess
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo
from pathlib import Path

import numpy as np
from PIL import Image, ImageCms, ImageDraw, ImageFont, ImageOps

PROJECT = Path(__file__).resolve().parent.parent
ROOT = PROJECT / "博主参考图库/光月大青蛙"
SRGB = ImageCms.createProfile("sRGB")


def dump(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False), encoding="utf-8")
    temporary.replace(path)


def folder_name(record):
    text = record.get("date_text", "")
    label = "日期未标明"
    full = re.search(r"(20\d{2})[-年/](\d{1,2})[-月/](\d{1,2})", text)
    short = re.search(r"(?<!\d)(\d{1,2})[-月/](\d{1,2})(?!\d)", text)
    relative = re.search(r"(\d+)天前", text)
    # Capture day is recorded explicitly, rather than inferred from file mtime.
    capture = date.fromisoformat(record.get("captured_on", datetime.now(ZoneInfo("Asia/Shanghai")).date().isoformat()))
    if full:
        label = date(*map(int, full.groups())).isoformat()
    elif "昨天" in text:
        label = (capture - timedelta(days=1)).isoformat()
    elif "今天" in text or "小时前" in text or "分钟前" in text:
        label = capture.isoformat()
    elif relative:
        label = (capture - timedelta(days=int(relative[1]))).isoformat()
    elif short:
        label = f"{int(short[1]):02d}-{int(short[2]):02d}"
    title = re.sub(r"[/\\:\x00-\x1f]", "_", record["title"]).strip()[:70]
    return f"{label}－{title}－{record['id'][-6:]}"


def ingest(records, inbox):
    files = [p for p in inbox.iterdir() if p.is_file() and p.suffix.lower() in {".webp", ".jpg", ".jpeg", ".png"}]
    def birth(p):
        stat = p.stat()
        return getattr(stat, "st_birthtime_ns", int(stat.st_birthtime * 1e9)), p.name
    files.sort(key=birth)
    names = {p.name: index for index, p in enumerate(files)}
    for record in records:
        ident = record["id"]
        if not re.fullmatch(r"[a-f0-9]{24}", ident):
            raise ValueError("Invalid post ID")
        record.setdefault("captured_on", datetime.now(ZoneInfo("Asia/Shanghai")).date().isoformat())
        record.setdefault("url", f"https://www.xiaohongshu.com/user/profile/5af2ad89f7e8b942e5fbaebd/{ident}")
        folder = ROOT / folder_name(record)
        output = folder / "post.json"
        if output.exists():
            previous = json.loads(output.read_text())
            if previous.get("count") == record["count"]:
                print(f"已归档 {ident}", flush=True)
                continue
            raise ValueError(f"Existing archive differs: {ident}")
        selected = []
        if record["count"]:
            start, end = names[record["first"]], names[record["last"]]
            selected = files[start:end+1]
            if len(selected) != record["count"]:
                raise ValueError(f"{ident}: expected {record['count']} files, found {len(selected)}; refusing ambiguous order")
        images = []
        for index, source in enumerate(selected, 1):
            target = folder / f"{index:03d}{source.suffix.lower()}"
            target.parent.mkdir(parents=True, exist_ok=True)
            if not target.exists():
                shutil.copy2(source, target)
            digest = hashlib.sha256(source.read_bytes()).hexdigest()
            if hashlib.sha256(target.read_bytes()).hexdigest() != digest:
                raise ValueError("Copy integrity mismatch")
            with Image.open(target) as image:
                image.load()
                size = list(ImageOps.exif_transpose(image).size)
                profile = "embedded ICC" if image.info.get("icc_profile") else "untagged; assumed sRGB for analysis"
            images.append({"file": str(target.relative_to(folder)), "source_filename": source.name,
                           "sha256": digest, "size": size, "profile": profile})
        saved = {**record, "author": "光月大青蛙", "images": images,
                 "source_quality": "Website-served images, not camera originals; downloaded bytes preserved"}
        dump(output, saved)
        print(f"归档 {ident}: {len(images)} 张", flush=True)


def open_rgb(path):
    image = Image.open(path)
    icc = image.info.get("icc_profile")
    image = ImageOps.exif_transpose(image).convert("RGB")
    if icc:
        image = ImageCms.profileToProfile(image, ImageCms.ImageCmsProfile(io.BytesIO(icc)), SRGB, outputMode="RGB")
    image.thumbnail((1100, 1100), Image.Resampling.LANCZOS)
    return image


def lab(rgb):
    linear = np.where(rgb <= 0.04045, rgb/12.92, ((rgb+0.055)/1.055)**2.4)
    xyz = linear @ np.array([[0.4124564,0.3575761,0.1804375],
                             [0.2126729,0.7151522,0.0721750],
                             [0.0193339,0.1191920,0.9503041]]).T
    t = xyz / [0.95047,1,1.08883]
    f = np.where(t > (6/29)**3, np.cbrt(t), t/(3*(6/29)**2)+4/29)
    return np.stack([116*f[...,1]-16,500*(f[...,0]-f[...,1]),200*(f[...,1]-f[...,2])],axis=-1)


def distribution(values):
    q = np.percentile(values, [1,10,25,50,75,90,99])
    return {key:round(float(value),3) for key,value in zip(["p01","p10","p25","median","p75","p90","p99"],q)}


def measure(rgb, values, selection):
    n = int(selection.sum())
    if n < 100:
        return {"ok":False,"sample_count":n,"fraction":round(float(selection.mean()),5) if selection.size else 0.0}
    samples = values[selection]
    chroma = np.hypot(samples[:,1],samples[:,2])
    # Hue is undefined near neutral; report a chroma-weighted circular mean.
    use = chroma > 6
    hue = float(np.degrees(np.arctan2(samples[use,2].mean(), samples[use,1].mean()))%360) if use.sum()>50 else None
    # Palette uses quantised RGB bins and retains exact bin population shares.
    colors = rgb[selection]
    bins = np.minimum((colors*8).astype(int),7)
    keys = bins[:,0]*64+bins[:,1]*8+bins[:,2]
    counts = np.bincount(keys,minlength=512)
    palette = []
    for key in np.argsort(counts)[::-1][:5]:
        if not counts[key]: continue
        color = np.round(colors[keys==key].mean(axis=0)*255).astype(int)
        palette.append({"hex":"#"+"".join(f"{c:02x}" for c in color), "share":round(float(counts[key]/n),4)})
    return {"ok":True,"sample_count":n,"fraction":round(float(selection.mean()),5),
            "L":distribution(samples[:,0]),"a":distribution(samples[:,1]),"b":distribution(samples[:,2]),
            "C":distribution(chroma),"hue_degrees":round(hue,2) if hue is not None else None,
            "bright_fraction_L_above_98":round(float((samples[:,0]>98).mean()),5),
            "dark_fraction_L_below_2":round(float((samples[:,0]<2).mean()),5),"palette":palette}


def font(size):
    return ImageFont.truetype("/System/Library/Fonts/STHeiti Light.ttc",size)


def contact_sheet(folder, post):
    images = post["images"]
    if not images: return
    cell_w, cell_h, columns = 220, 310, 5
    rows = (len(images)+columns-1)//columns
    canvas = Image.new("RGB",(columns*cell_w,rows*cell_h+60),(24,24,24))
    draw=ImageDraw.Draw(canvas)
    draw.text((14,14),post["title"],font=font(20),fill="white")
    for index,record in enumerate(images):
        image=open_rgb(folder/record["file"])
        image.thumbnail((cell_w-12,cell_h-36),Image.Resampling.LANCZOS)
        x=(index%columns)*cell_w+(cell_w-image.width)//2
        y=(index//columns)*cell_h+60
        canvas.paste(image,(x,y))
        draw.text(((index%columns)*cell_w+10,y+cell_h-30),f"{index+1:03d}",font=font(15),fill="white")
    (folder/"分析").mkdir(exist_ok=True)
    canvas.save(folder/"分析/图集总览.jpg",quality=90)


def analyze(folder):
    post=json.loads((folder/"post.json").read_text())
    result=folder/"分析/特征.json"
    if result.exists():
        if not (folder/"分析/图集总览.jpg").exists(): contact_sheet(folder,post)
        return
    if not post["images"]:
        dump(result,{"id":post["id"],"title":post["title"],"status":"video_or_unavailable","images":[]})
        return
    maskroot=folder/"分析/蒙版"
    binary=PROJECT/".build/debug/ReferenceMasks"
    subprocess.run([str(binary),"--output",str(maskroot),*[str(folder/i["file"]) for i in post["images"]]],check=True)
    records=[]
    for record in post["images"]:
        path=folder/record["file"]
        image=open_rgb(path)
        rgb=np.asarray(image,dtype=np.float64)/255
        values=lab(rgb)
        def mask(name):
            with Image.open(maskroot/path.stem/(name+".png")) as m:
                return np.asarray(m.convert("L").resize(image.size,Image.Resampling.BILINEAR))/255
        face,cloth,person=mask("face"),mask("clothing"),mask("person")
        selections={"global":np.ones(rgb.shape[:2],dtype=bool),"face_skin":face>0.95,
                    "clothing":(cloth>0.90)&(person>0.90)&(face<0.05),"background":person<0.05}
        stats={k:measure(rgb,values,v) for k,v in selections.items()}
        records.append({**record,"analysis_size":list(image.size),"regions":stats})
        # One overlay per image allows segmentation errors to be audited.
        overlay=rgb.copy()
        for key,color in [("background",[0.9,0.15,0.15]),("clothing",[0.2,0.3,1]),("face_skin",[0.1,0.9,0.2])]:
            m=selections[key]; overlay[m]=overlay[m]*0.55+np.array(color)*0.45
        Image.fromarray(np.round(overlay*255).astype(np.uint8)).save(maskroot/path.stem/"overlay.jpg",quality=85)
    summary={}
    for region in ["global","face_skin","clothing","background"]:
        good=[r["regions"][region] for r in records if r["regions"][region]["ok"]]
        summary[region]={"valid_images":len(good)}
        for channel in ["L","a","b","C"]:
            if good: summary[region][channel]=distribution([g[channel]["median"] for g in good])
    dump(result,{"id":post["id"],"title":post["title"],"source":post["url"],"status":"complete",
                 "method":"ICC to sRGB; Lab D65; confidence-thresholded native semantic masks; equal image weighting",
                 "summary":summary,"images":records,
                 "limitations":["Masks are estimates; inspect overlays before using as a style target",
                                "Face skin excludes lips/eyes/hair; arms/legs are not included",
                                "Statistics include lighting, makeup and web compression; not original editing parameters"]})
    contact_sheet(folder,post)
    print(f"提取 {post['id']}: {len(records)} 张",flush=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action",choices=["ingest","analyze"])
    parser.add_argument("--records",type=Path)
    parser.add_argument("--inbox",type=Path,default=Path.home()/"Downloads")
    args=parser.parse_args()
    if args.action=="ingest":
        ingest(json.loads(args.records.read_text()),args.inbox)
    else:
        for source in sorted(ROOT.glob("*/post.json")):
            try: analyze(source.parent)
            except Exception as error:
                dump(source.parent/"分析/分析失败.json",{"error":str(error)})
                print(f"失败 {source.parent.name}: {error}",flush=True)


if __name__=="__main__": main()
