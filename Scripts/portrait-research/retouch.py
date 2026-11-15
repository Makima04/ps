#!/usr/bin/env python3
"""Compare official ModelScope local repair and blend layers independently.

Uses the publisher's unchanged retouch_local/predict_roi method bodies, without
the full ModelScope/TensorFlow framework. Vision supplies the already detected
face box. Whitening is off so colour changes do not obscure the repair test.
"""
import argparse
import ast
import gc
import importlib
import time
import types

import cv2
import numpy as np
from PIL import Image
import torch
import torch.nn as nn
import torch.nn.functional as F

from common import (PROJECT, ROOT, OUTPUT, face_crop, read_srgb, save_rgb,
                    save_json, namespace, digest, overlay)


def modules():
    base = ROOT/'repos/modelscope/modelscope'
    for name,folder in [('modelscope',base),('modelscope.models',base/'models'),
        ('modelscope.models.cv',base/'models/cv'),
        ('modelscope.models.cv.skin_retouching',base/'models/cv/skin_retouching')]:
        namespace(name,folder)
    prefix = 'modelscope.models.cv.skin_retouching.'
    detector = importlib.import_module(prefix+'detection_model.detection_unet_in')
    painter = importlib.import_module(prefix+'inpainting_model.inpainting_unet')
    generator = importlib.import_module(prefix+'unet_deploy')
    utils = importlib.import_module(prefix+'utils')
    return detector,painter,generator,utils


def bind_official_methods(instance,utils):
    source = ROOT/'modelscope-wrapper.py'
    parsed = ast.parse(source.read_text())
    cls = next(node for node in parsed.body if isinstance(node,ast.ClassDef))
    methods = [node for node in cls.body if isinstance(node,ast.FunctionDef)
        and node.name in ['retouch_local','predict_roi']]
    environment = dict(torch=torch,F=F,np=np,**{name:getattr(utils,name) for name in utils.__all__})
    exec(compile(ast.Module(body=methods,type_ignores=[]),str(source),'exec'),environment)
    for node in methods:
        setattr(instance,node.name,types.MethodType(environment[node.name],instance))


class Capture(nn.Module):
    def __init__(self,model):
        super().__init__()
        self.model = model
        self.last = None

    def forward(self,image):
        out = self.model(image)
        self.last = out.detach()
        return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--stems',nargs='+',default=['DSC00372','DSC01197'])
    parser.add_argument('--device',choices=['mps','cpu'],default='mps')
    parser.add_argument('--input-kind',choices=['current','camera'],default='current')
    args = parser.parse_args()
    torch.set_num_threads(4)
    if args.device=='mps':
        torch.mps.set_per_process_memory_fraction(0.55)
    device = torch.device(args.device)
    tick = time.monotonic()
    det,paint,gen,utils = modules()
    local_checkpoint = ROOT/'models/modelscope-joint_20210926.pth'
    generator_checkpoint = ROOT/'models/modelscope-pytorch_model.pt'
    weights = torch.load(local_checkpoint,map_location='cpu',weights_only=True)
    detection = det.DetectionUNet(n_channels=3,n_classes=1)
    detection.load_state_dict(weights['detection_net'],strict=True)
    inpainting = paint.RetouchingNet(in_channels=4,out_channels=3,init_weights=False)
    inpainting.load_state_dict(weights['inpainting_net'],strict=True)
    del weights
    generator = gen.UNet(3,3)
    weights = torch.load(generator_checkpoint,map_location='cpu',weights_only=True)
    generator.load_state_dict(weights['generator'],strict=True)
    del weights
    # RetouchingNet.train() in the upstream implementation returns None.
    # Keep eval and device transfer separate rather than chaining them.
    generator.eval()
    inpainting.eval()
    detection.eval()
    pipeline = types.SimpleNamespace(device=device,patch_size=512,input_size=512,
        generator=generator.to(device),inpainting_net=inpainting.to(device),
        detection_net=Capture(detection.to(device)),
        diffuse_mask=torch.from_numpy(utils.gen_diffuse_mask()).permute(2,0,1)[None].to(device))
    bind_official_methods(pipeline,utils)
    gc.collect()
    setup_seconds = time.monotonic()-tick
    print('ModelScope 模型已加载',args.device,round(setup_seconds,2),'秒',flush=True)
    for stem in args.stems:
        source = (PROJECT/'成片/跨组反馈修订-4张'/(stem+'-反馈修订.jpg') if args.input_kind=='current'
            else PROJECT/'100MSDCF'/(stem+'.JPG'))
        image = read_srgb(source)
        base = np.asarray(image).copy()
        crop = face_crop(stem,image.size,factor=1.5)
        l,t,r,b = crop
        rgb = base[t:b,l:r].copy()
        tensor = torch.from_numpy(rgb.transpose(2,0,1).copy())[None].to(device).float()/127.5-1
        folder = OUTPUT/'瑕疵'/stem
        if args.input_kind=='camera':
            folder = folder/'相机JPEG验证'
        if args.device=='cpu':
            folder = folder/'CPU核验'
        folder.mkdir(parents=True,exist_ok=True)
        save_rgb(image,folder/('输入-0.4.2.jpg' if args.input_kind=='current' else '输入-相机JPEG.jpg'))
        skin = np.asarray(Image.open(ROOT/'current-masks'/stem/'face.png').convert('L'),dtype=np.float32)/255
        skin = cv2.resize(skin,image.size,interpolation=cv2.INTER_LINEAR)[t:b,l:r]
        skin = cv2.erode(skin,np.ones((3,3),np.uint8))
        skin = cv2.GaussianBlur(skin,(0,0),1.0)
        tick = time.monotonic()
        with torch.inference_mode():
            local = pipeline.retouch_local(tensor)
            local_rgb = ((local[0].permute(1,2,0).float().cpu().numpy()+1)*127.5).clip(0,255)
            probability = torch.sigmoid(pipeline.detection_net.last)[0,0].cpu().numpy()
        local_seconds = time.monotonic()-tick
        probability = cv2.resize(probability,(r-l,b-t),interpolation=cv2.INTER_LINEAR)
        Image.fromarray((probability*255).astype(np.uint8)).save(folder/'模型瑕疵概率-局部.png')
        save_rgb(overlay(image.crop(crop),probability,color=(245,80,65)),folder/'模型瑕疵预测-覆盖.jpg')
        variants = {'局部修复':local_rgb}
        timings = {'局部修复':local_seconds}
        with torch.inference_mode():
            for degree in [0.35,0.7]:
                tick = time.monotonic()
                output = pipeline.predict_roi(local,degree=degree,smooth_border=True,return_mg=False)['pred']
                value = output.float().cpu().numpy()
                name = f'局部修复加柔化-{degree:.2f}'
                variants[name] = value
                timings[name] = local_seconds+time.monotonic()-tick
        records = []
        for name,edited in variants.items():
            if not np.isfinite(edited).all():
                raise RuntimeError('修复输出含 NaN/Inf')
            # Keep raw predictions visible: a skin gate can hide model errors.
            save_rgb(edited.clip(0,255).round().astype(np.uint8),folder/(name+'-未约束局部.png'))
            full = base.copy()
            selected = (rgb*(1-skin[...,None])+edited*skin[...,None]).clip(0,255).round().astype(np.uint8)
            full[t:b,l:r] = selected
            outside = skin<=0
            outside_error = int(np.abs(selected.astype(np.int16)-rgb.astype(np.int16))[outside].max(initial=0))
            if outside_error != 0:
                raise AssertionError('零蒙版区域被改变')
            save_rgb(full,folder/(name+'-皮肤约束.jpg'))
            save_rgb(selected,folder/(name+'-皮肤约束局部.png'))
            delta = np.abs(selected.astype(np.float32)-rgb.astype(np.float32))
            records.append(dict(name=name,inference_seconds=timings[name],
                mean_rgb_delta=float(delta.mean()),changed_pixels=int((delta.max(2)>2).sum()),
                outside_zero_mask_max_delta=outside_error))
        details = dict(model='iic/cv_unet_skin_retouching_torch',device=args.device,
            source=str(source),source_sha256=digest(source),crop=list(crop),crop_source='复用已有 Vision 自动人脸框，1.5倍方形裁切',
            setup_seconds=setup_seconds,whitening=False,local_retouching=True,
            original_wrapper_local_retouching_default=False,
            comparison_kind='在0.4.2成片上增量处理' if args.input_kind=='current' else '相机JPEG原像素验证',
            protocol_changes=['使用已有Vision框，未运行RetinaFace','关闭额外美白','额外提供当前皮肤蒙版约束版本'],
            local_checkpoint_sha256=digest(local_checkpoint),blend_checkpoint_sha256=digest(generator_checkpoint),
            publisher_wrapper_sha256=digest(ROOT/'modelscope-wrapper.py'),
            predicted_repair_fraction=float((probability>=.35).mean()),variants=records)
        save_json(details,folder/'运行记录.json')
        print(stem,'局部修复',round(local_seconds,3),'秒','候选比例',round(details['predicted_repair_fraction'],4),flush=True)
        del tensor,local,variants,base,full,selected
        if args.device=='mps':
            torch.mps.empty_cache()


if __name__=='__main__':
    main()
