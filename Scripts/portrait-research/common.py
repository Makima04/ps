"""Shared, colour-managed inputs and reversible research outputs."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import types

import cv2
import numpy as np
from PIL import Image, ImageCms, ImageOps

PROJECT = Path(__file__).resolve().parents[2]
ROOT = PROJECT / '.build/portrait-research-2026-11-12'
OUTPUT = PROJECT / '成片/开源算法对比-2026-11-12'
SRGB = ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes()


def read_srgb(path):
    with Image.open(path) as original:
        image = ImageOps.exif_transpose(original).convert('RGB')
        if profile := original.info.get('icc_profile'):
            image = ImageCms.profileToProfile(image, ImageCms.ImageCmsProfile(io.BytesIO(profile)),
                ImageCms.createProfile('sRGB'), outputMode='RGB')
    return image


def save_rgb(image, path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(image, np.ndarray):
        image = Image.fromarray(image)
    image.save(path, icc_profile=SRGB, **({'quality':97, 'subsampling':0} if path.suffix.lower() in ['.jpg','.jpeg'] else {}))


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda:stream.read(4*1024*1024),b''):
            h.update(block)
    return h.hexdigest()


def face_bounds(stem):
    records = json.loads((PROJECT / '.build/cross-group-qa' / stem / 'faces.json').read_text())
    return max(records, key=lambda item:item['bounds'][2])['bounds']


def face_crop(stem, size, factor=2.1):
    width, height = size
    x,y,w,h = face_bounds(stem)
    side = max(w*factor,h*1.8) if factor == 2.1 else max(w,h)*factor
    cx,cy = x+w/2,height-(y+h/2+h*0.05)
    return (max(0,int(cx-side/2)),max(0,int(cy-side/2)),
        min(width,int(cx+side/2+0.999)),min(height,int(cy+side/2+0.999)))


def namespace(name, path):
    module = types.ModuleType(name)
    module.__path__ = [str(path)]
    sys.modules[name] = module


def module_file(name, path):
    spec = importlib.util.spec_from_file_location(name,path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def save_json(value,path):
    path = Path(path)
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(value,ensure_ascii=False,indent=2))


def overlay(image, mask, color=(40,225,155), alpha=0.45):
    values = np.asarray(image,dtype=np.float32)
    weights = np.asarray(mask,dtype=np.float32)
    if weights.max() > 1:
        weights /= 255
    return np.clip(values*(1-alpha*weights[...,None])+np.array(color)*alpha*weights[...,None],0,255).astype(np.uint8)


def subject_crop(stem,size):
    # The current automatic person mask supplies only a bounding box. Its
    # silhouette is NOT multiplied into a new model's prediction.
    from scipy import ndimage
    mask = np.asarray(Image.open(ROOT/'current-masks'/stem/'person.png').convert('L')) > 128
    labels,_ = ndimage.label(mask)
    x,y,w,h = face_bounds(stem)
    xx = min(mask.shape[1]-1,int((x+w/2)/size[0]*mask.shape[1]))
    yy = min(mask.shape[0]-1,int((size[1]-y-h/2)/size[1]*mask.shape[0]))
    own = labels[yy,xx]
    if own == 0:
        return (0,0,*size)
    ys,xs = np.where(labels==own)
    sx,sy = size[0]/mask.shape[1],size[1]/mask.shape[0]
    pad = 0.035*max(size)
    return (max(0,int(xs.min()*sx-pad)),max(0,int(ys.min()*sy-pad)),
        min(size[0],int((xs.max()+1)*sx+pad)),min(size[1],int((ys.max()+1)*sy+pad)))
