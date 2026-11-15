#!/usr/bin/env python3
"""Run publisher segmentation weights on the same camera JPEG as ColorEngine."""
import argparse
import gc
import importlib
import json
import time

import cv2
import numpy as np
from PIL import Image
import torch
import torch.nn as nn
import torch.nn.functional as F
from safetensors.torch import load_file

from common import (PROJECT, ROOT, OUTPUT, face_crop, subject_crop, read_srgb,
                    save_rgb, save_json, namespace, module_file, overlay, digest)

SEGFACE_LABELS = ['background','neck','skin','cloth','l_ear','r_ear','l_brow','r_brow',
    'l_eye','r_eye','nose','mouth','lower_lip','upper_lip','hair','glasses','hat','earring','necklace']
SAPIENS_LABELS = ['background','apparel','glasses','face_neck','hair','l_foot','l_hand',
    'l_lower_arm','l_lower_leg','l_shoe','l_sock','l_upper_arm','l_upper_leg','lower_clothing',
    'r_foot','r_hand','r_lower_arm','r_lower_leg','r_shoe','r_sock','r_upper_arm','r_upper_leg',
    'torso','upper_clothing','lower_lip','upper_lip','lower_teeth','upper_teeth','tongue']


def load_segface(backbone):
    repo = ROOT/'repos/SegFace'
    namespace('network',repo/'network')
    namespace('network.models',repo/'network/models')
    module = importlib.import_module('network.models.segface_celeb')
    # All backbone parameters are already in the SegFace checkpoint. Suppress
    # redundant ImageNet downloads; strict loading verifies complete coverage.
    constructor_name = 'mobilenet_v3_large' if backbone=='mobile' else 'swin_b'
    constructor = getattr(module,constructor_name)
    def without_imagenet(*args,**kwargs):
        kwargs.pop('pretrained',None)
        kwargs['weights'] = None
        return constructor(*args,**kwargs)
    setattr(module,constructor_name,without_imagenet)
    model = module.SegFaceCeleb(512,'mobilenet' if backbone=='mobile' else 'swin_base')
    checkpoint = ROOT/'models'/f'segface-{backbone}.pt'
    weights = torch.load(checkpoint,map_location='cpu',weights_only=True)
    state = weights['state_dict_backbone']
    state = {key.removeprefix('module.'):value for key,value in state.items()}
    model.load_state_dict(state,strict=True)
    del weights,state
    return model,checkpoint


class SapiensSeg(nn.Module):
    def __init__(self):
        super().__init__()
        repo = ROOT/'repos/sapiens2/sapiens'
        namespace('sapiens',repo)
        backbone = module_file('research_sapiens_backbone',repo/'backbones/standalone/sapiens2.py')
        head = module_file('research_sapiens_head',repo/'dense/src/models/heads/seg_head.py')
        self.backbone = backbone.Sapiens2(arch='sapiens2_0.4b',img_size=(1024,768),
            patch_size=16,out_type='featmap',final_norm=True,use_tokenizer=False)
        self.decode_head = head.SegHead(in_channels=1024,deconv_out_channels=(512,256,128,64),
            deconv_kernel_sizes=(4,4,4,4),conv_out_channels=(64,64),conv_kernel_sizes=(1,1),
            num_classes=29,loss_decode=[])

    def forward(self,image):
        return self.decode_head(self.backbone(image)[0])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--model',choices=['segface-mobile','segface-swin','sapiens2'],required=True)
    parser.add_argument('--stems',nargs='+',default=['DSC01063'])
    parser.add_argument('--device',choices=['mps','cpu'],default='mps')
    parser.add_argument('--subject-crop',action='store_true')
    parser.add_argument('--precision',choices=['fp16','fp32'],default='fp16')
    args = parser.parse_args()
    torch.set_num_threads(4)
    torch.manual_seed(0)
    if args.device=='mps':
        if not torch.backends.mps.is_available():
            raise RuntimeError('本机 MPS 不可用，可使用 --device cpu')
        torch.mps.set_per_process_memory_fraction(0.55)
    device = torch.device(args.device)
    started = time.monotonic()
    if args.model.startswith('segface'):
        model,checkpoint = load_segface(args.model.split('-')[1])
        labels = SEGFACE_LABELS
        input_wh = (512,512)
    else:
        model = SapiensSeg()
        checkpoint = ROOT/'models/sapiens2-seg-0.4b.safetensors'
        model.load_state_dict(load_file(checkpoint),strict=True)
        labels = SAPIENS_LABELS
        input_wh = (768,1024)
    # FP32 for SegFace; FP16 for the larger Sapiens2 experiment on 16GB Macs.
    dtype = torch.float16 if args.model=='sapiens2' and args.device=='mps' and args.precision=='fp16' else torch.float32
    model.eval().to(device=device,dtype=dtype)
    gc.collect()
    setup_seconds = time.monotonic()-started
    print('模型已加载',args.model,'设备',args.device,'精度',str(dtype),flush=True)
    for stem in args.stems:
        source = PROJECT/'100MSDCF'/(stem+'.JPG')
        image = read_srgb(source)
        if args.model.startswith('segface'):
            crop = face_crop(stem,image.size)
        else:
            crop = subject_crop(stem,image.size) if args.subject_crop else (0,0,*image.size)
        small = image.crop(crop).resize(input_wh,Image.Resampling.BILINEAR)
        array = np.asarray(small,dtype=np.float32)/255
        array = (array-np.array([.485,.456,.406],np.float32))/np.array([.229,.224,.225],np.float32)
        tensor = torch.from_numpy(array.transpose(2,0,1).copy())[None].to(device=device,dtype=dtype)
        tick = time.monotonic()
        with torch.inference_mode():
            logits = model(tensor,None,None) if args.model.startswith('segface') else model(tensor)
            if not torch.isfinite(logits).all().item():
                raise RuntimeError('模型输出含 NaN/Inf，结果不可用于对比')
            logits = logits.float().cpu()
        elapsed = time.monotonic()-tick
        raw = logits.argmax(1)[0].numpy().astype(np.uint8)
        predicted = np.zeros((image.height,image.width),dtype=np.uint8)
        l,t,r,b = crop
        predicted[t:b,l:r] = cv2.resize(raw,(r-l,b-t),interpolation=cv2.INTER_NEAREST)
        variant = args.model+('-subject' if args.subject_crop else '')
        if args.model=='sapiens2' and args.precision=='fp32':
            variant += '-fp32'
        folder = OUTPUT/'选区'/stem/variant
        folder.mkdir(parents=True,exist_ok=True)
        Image.fromarray(predicted).save(folder/'类别.png')
        groups = ({'脸颈':[1,2,4,5,10],'颈部':[1],'头发':[14],'嘴唇':[12,13]} if args.model.startswith('segface')
            else {'脸颈':[3],'头发':[4],'手部':[6,15],'手臂':[7,11,16,20],'嘴唇':[24,25]})
        for name,indices in groups.items():
            mask = np.isin(predicted,indices).astype(np.uint8)*255
            Image.fromarray(mask).save(folder/(name+'.png'))
            thumb = image.copy()
            thumb.thumbnail((1100,1100),Image.Resampling.LANCZOS)
            weight = cv2.resize(mask,thumb.size,interpolation=cv2.INTER_AREA)
            save_rgb(overlay(thumb,weight),folder/(name+'-覆盖.jpg'))
        details = dict(model=args.model,variant=variant,device=args.device,dtype=str(dtype),
            source=str(source),source_sha256=digest(source),crop=list(crop),input_size=list(input_wh),
            labels=labels,setup_seconds=setup_seconds,inference_seconds=elapsed,
            checkpoint=str(checkpoint),checkpoint_sha256=digest(checkpoint),
            class_pixels={labels[i]:int((predicted==i).sum()) for i in range(len(labels))})
        save_json(details,folder/'运行记录.json')
        print(stem,variant,'推理',round(elapsed,3),'秒',flush=True)
        del tensor,logits,predicted
        if args.device=='mps':
            torch.mps.empty_cache()


if __name__=='__main__':
    main()
