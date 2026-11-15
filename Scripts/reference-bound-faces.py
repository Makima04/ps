#!/usr/bin/env python3
"""Constrain cached face masks to the main detected face and refresh face stats.

This changes derived masks/reports only. Source photographs are never written.
Clothing/background retain their existing conservative high-confidence samples.
"""
import argparse
import importlib.util
import json
from pathlib import Path

import numpy as np
from PIL import Image

spec=importlib.util.spec_from_file_location("library",Path(__file__).with_name("reference-library.py"))
lib=importlib.util.module_from_spec(spec);spec.loader.exec_module(lib)


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("bounds",type=Path)
    args=parser.parse_args()
    bounds={str(Path(row["file"]).resolve()):row["faces"] for row in json.loads(args.bounds.read_text())}
    checked=0;removed=0;missing=0
    for metadata in sorted(lib.ROOT.glob("*/post.json")):
        post=json.loads(metadata.read_text());folder=metadata.parent
        if not post["images"]:continue
        report_path=folder/"分析/特征.json"
        report=json.loads(report_path.read_text())
        by_file={row["file"]:row for row in report["images"]}
        for entry in post["images"]:
            source=folder/entry["file"]
            faces=bounds[str(source.resolve())]
            best=max(faces,key=lambda row:row["width"]*row["height"]) if faces else None
            directory=folder/"分析/蒙版"/source.stem
            image=lib.open_rgb(source)
            rgb=np.asarray(image,dtype=np.float32)/255
            with Image.open(directory/"face.png") as m:
                original=np.asarray(m.convert("L").resize(image.size,Image.Resampling.BILINEAR)).copy()
            with Image.open(directory/"person.png") as m:
                person=np.asarray(m.convert("L").resize(image.size,Image.Resampling.BILINEAR))/255
            with Image.open(directory/"clothing.png") as m:
                clothing=np.asarray(m.convert("L").resize(image.size,Image.Resampling.BILINEAR))/255
            h,w=original.shape
            rectangle=np.zeros((h,w),dtype=bool)
            if best:
                x0=max(0,int(np.floor(best["x"]*w)));x1=min(w,int(np.ceil((best["x"]+best["width"])*w)))
                y0=max(0,int(np.floor(best["y"]*h)));y1=min(h,int(np.ceil((best["y"]+best["height"])*h)))
                rectangle[y0:y1,x0:x1]=True
            else:missing+=1
            clean=original.copy()
            clean[~rectangle|(person<0.5)]=0
            removed+=int(((original>243)&(clean<=243)).sum())
            temporary=directory/"face.tmp.png"
            Image.fromarray(clean).save(temporary)
            temporary.replace(directory/"face.png")
            selection=clean>243
            samples=rgb[selection].astype(np.float64)
            values=lib.lab(samples)
            stats=lib.measure(samples,values,np.ones(len(samples),dtype=bool))
            stats["fraction"]=round(float(selection.mean()),5)
            stats["face_bounds_normalized"]=best
            by_file[entry["file"]]["regions"]["face_skin"]=stats
            # Keep inspection overlays consistent with the accepted selections.
            overlay=np.asarray(image).copy()
            selections={"background":person<0.05,"clothing":(clothing>0.90)&(person>0.90)&(clean<13),"face_skin":selection}
            for region,color in [("background",[0.9,0.15,0.15]),("clothing",[0.2,0.3,1]),("face_skin",[0.1,0.9,0.2])]:
                mask=selections[region]
                overlay[mask]=np.round(overlay[mask].astype(np.float32)*0.55+np.array(color)*255*0.45).astype(np.uint8)
            Image.fromarray(overlay).save(directory/"overlay.jpg",quality=85)
            checked+=1
        good=[row["regions"]["face_skin"] for row in report["images"] if row["regions"]["face_skin"]["ok"]]
        summary={"valid_images":len(good)}
        for channel in ["L","a","b","C"]:
            if good:summary[channel]=lib.distribution([row[channel]["median"] for row in good])
        report["summary"]["face_skin"]=summary
        report["face_selection"]="Largest Vision face rectangle intersected with semantic skin and person masks; eyes and lips excluded"
        report["face_mask_bounds_verified"]=True
        lib.dump(report_path,report)
        if checked%100<post["count"]:print(f"复核肤色 {checked}",flush=True)
    audit={"checked_images":checked,"removed_out_of_face_pixels":removed,"images_without_reliable_face":missing,
           "source_photos_modified":False}
    lib.dump(lib.ROOT/"脸部选区复核.json",audit)
    print(audit,flush=True)


if __name__=="__main__":main()
