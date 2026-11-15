#!/usr/bin/env python3
"""Build matched crops and an evidence report; no learned accuracy is inferred."""
from pathlib import Path
import json
import shutil

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageOps

from common import PROJECT, ROOT, OUTPUT, SRGB, read_srgb, save_rgb, save_json, face_bounds, face_crop, overlay

FONT = '/System/Library/Fonts/STHeiti Medium.ttc'
FONTS = {size:ImageFont.truetype(FONT,size) for size in [16,18,21,24,30]}
BG = '#f4f1ed'
INK = '#332e2a'
MUTED = '#69625c'


def text(draw,xy,value,size=21,fill=INK):
    draw.text(xy,value,font=FONTS[size],fill=fill)


def paste_fit(canvas,image,box):
    l,t,r,b = box
    fitted = ImageOps.contain(image,(r-l,b-t),Image.Resampling.LANCZOS)
    canvas.paste(fitted,(l+(r-l-fitted.width)//2,t+(b-t-fitted.height)//2))


def retouch_board(stem):
    folder = OUTPUT/'瑕疵'/stem
    record = json.loads((folder/'运行记录.json').read_text())
    before = read_srgb(record['source'])
    l,t,r,b = record['crop']
    variants = ['局部修复','局部修复加柔化-0.35','局部修复加柔化-0.70']
    images = [before.crop((l,t,r,b))]+[Image.open(folder/(name+'-皮肤约束局部.png')).convert('RGB') for name in variants]
    names = ['现有 0.4.2','模型局部修复','局部修复＋柔化 0.35','局部修复＋柔化 0.70']
    x,y,w,h = face_bounds(stem)
    top = before.height-y-h
    overview = (int(x-w*.12)-l,int(top-h*.12)-t,int(x+w*1.12)-l,int(top+h*1.12)-t)
    board = Image.new('RGB',(1680,1720),BG)
    draw = ImageDraw.Draw(board)
    text(draw,(24,16),stem+' · 现成修复模型对比',30)
    text(draw,(24,60),'同一张 0.4.2 成片作为输入；关闭额外美白，后三列受相同皮肤蒙版约束。',21,MUTED)
    for col,(image,label) in enumerate(zip(images,names)):
        xx = col*420+14
        text(draw,(xx,108),label,21)
        paste_fit(board,image.crop(overview),(xx,150,xx+392,550))
    patches = [('鼻部：黑头与正常毛孔',.50,.50),('画面左颊：色斑与纹理',.20,.47),
               ('画面右颊：色斑与纹理',.80,.48)]
    if stem=='DSC01197':
        patches[-1] = ('唇缘：检查保护范围',.50,.73)
    for row,(label,px,py) in enumerate(patches):
        yy = 575+row*355
        text(draw,(24,yy),label+' · 400×270 原像素裁切，无缩放',21,MUTED)
        cx,cy = int(x+w*px)-l,int(top+h*py)-t
        box = (cx-200,cy-135,cx+200,cy+135)
        for col,image in enumerate(images):
            board.paste(image.crop(box),(col*420+10,yy+42))
    text(draw,(24,1650),'这些是局部效果核验，不是瑕疵类别准确率；图中保留的斑点仍需逐项确认。',21,MUTED)
    save_rgb(board,OUTPUT/(stem+'-瑕疵模型对比.jpg'))


def mask_board():
    stem = 'DSC01063'
    source = read_srgb(PROJECT/'100MSDCF'/(stem+'.JPG'))
    box = face_crop(stem,source.size)
    selected = [
        ('现有 0.4.2',ROOT/'current-masks'/stem/'face.png'),
        ('SegFace · Mobile',OUTPUT/'选区'/stem/'segface-mobile/脸颈.png'),
        ('SegFace · Swin',OUTPUT/'选区'/stem/'segface-swin/脸颈.png'),
        ('Sapiens2 · FP32',OUTPUT/'选区'/stem/'sapiens2-fp32/脸颈.png'),
    ]
    board = Image.new('RGB',(1840,1260),BG)
    draw = ImageDraw.Draw(board)
    text(draw,(24,16),'DSC01063 · 脸颈选区对比',30)
    text(draw,(24,62),'相同相机 JPEG、相同显示裁切；绿色表示模型选中的脸颈，不表示真实皮肤标注。',21,MUTED)
    for col,(label,path) in enumerate(selected):
        xx = col*460+14
        mask = Image.open(path).convert('L').resize(source.size,Image.Resampling.NEAREST)
        region = source.crop(box)
        weight = mask.crop(box)
        text(draw,(xx,112),label,24)
        paste_fit(board,Image.fromarray(overlay(region,weight)),(xx,154,xx+432,640))
        paste_fit(board,weight.convert('RGB'),(xx,680,xx+432,1160))
    text(draw,(24,1200),'重点核对：发丝覆盖下仍可见的皮肤、颈部、贴近下巴的手指，以及假耳道具的误选。',21,MUTED)
    save_rgb(board,OUTPUT/'DSC01063-脸颈选区对比.jpg')
    # Body part masks are kept separate from bare-skin semantics.
    current = Image.open(ROOT/'current-masks'/stem/'body.png').convert('L').resize(source.size,Image.Resampling.NEAREST)
    folder = OUTPUT/'选区'/stem/'sapiens2-fp32'
    limbs = np.maximum(np.asarray(Image.open(folder/'手部.png')),np.asarray(Image.open(folder/'手臂.png')))
    labels = ['相机 JPEG','现有身体皮肤候选','Sapiens2 手／臂部位候选']
    images = [source,Image.fromarray(overlay(source,current)),Image.fromarray(overlay(source,limbs))]
    body = Image.new('RGB',(1860,1150),BG)
    bd = ImageDraw.Draw(body)
    text(bd,(24,16),'DSC01063 · 手部与手臂覆盖',30)
    text(bd,(24,60),'Sapiens2 的部位类别包含整个手／手臂，后续还需排除指甲、衣物、道具等非皮肤像素。',21,MUTED)
    for col,(image,label) in enumerate(zip(images,labels)):
        xx = col*620+14
        text(bd,(xx,106),label,24)
        paste_fit(body,image,(xx,152,xx+590,1100))
    save_rgb(body,OUTPUT/'DSC01063-手臂选区对比.jpg')


def summary():
    timings = []
    for path in sorted((OUTPUT/'选区').rglob('运行记录.json')):
        data = json.loads(path.read_text())
        timings.append(dict(photo=path.parents[1].name,model=data['variant'],device=data['device'],
            dtype=data['dtype'],setup_seconds=data['setup_seconds'],inference_seconds=data['inference_seconds']))
    for path in sorted((OUTPUT/'瑕疵').rglob('运行记录.json')):
        data = json.loads(path.read_text())
        timings.append(dict(photo=Path(data['source']).stem,model=data['model'],device=data['device'],
            stage=data['comparison_kind'],setup_seconds=data['setup_seconds'],variants=data['variants']))
    save_json(timings,OUTPUT/'运行时间汇总.json')
    shutil.copy2(ROOT/'model-manifest.json',OUTPUT/'模型来源与校验.json')
    shutil.copy2(ROOT/'requirements-lock.txt',OUTPUT/'Python依赖锁定.txt')
    download = json.loads((ROOT/'retouchformer-download-status.json').read_text())
    download.update(browser_access='blocked_by_site_safety_policy',inference_performed=False,
        explanation='百度网盘官方页面访问被浏览器站点安全策略阻止；没有绕过限制或继续下载。')
    save_json(download,ROOT/'retouchformer-download-status.json')
    save_json(download,OUTPUT/'RetouchFormer状态.json')
    report = '''# 开源算法首次实测 · 2026-11-12

本轮为独立离线对比，未改动 Swift / Core Image 正式处理链、项目记录或原有成片。

## 已运行的模型

- ModelScope `iic/cv_unet_skin_retouching_torch`：分别在 372、1197 的 0.4.2 成片和相机 JPEG 上运行局部修复，以及附加 0.35 / 0.70 强度的混合图层。额外美白关闭；既保存原始局部输出，也保存现有皮肤蒙版约束后的结果。
- SegFace Mobile 和 Swin：在 1063、372、1197 的相机 JPEG 上，复用现有自动人脸框的头部裁切进行推理。使用发布者的 ImageNet 归一化和完整分割权重；没有额外下载 ImageNet 权重或训练模型。
- Sapiens2-0.4B：在三张完整相机 JPEG 上推理；1063 另有主人物裁切测试和 FP32 精度核验。分割权重约 1.5 GiB。完整的手和手臂类别并不等同于裸露皮肤蒙版。

## 看图后的初步取舍

1. **优先保留 Sapiens2 的身体分割路线继续验证。** 1063 的手与手臂覆盖更完整、连贯，减少了现有几何走廊造成的漏选。它仍会选入假耳道具，发丝交界也不完美，不能直接作为最终自动调色蒙版。
2. **SegFace 可以作为脸颈解析候选，但目前没有全面胜出。** 两种骨干对颈部覆盖有所不同，Mobile 在下巴附近混入了一小段手指，Swin 会把假耳道具选入脸颈。不能仅凭公开数据集成绩就替换现有模型。
3. **这版 ModelScope 权重不足以解决 372 的全部瑕疵。** 局部预测能标出少量异常点，但小黄斑与鼻部细小点状纹理仍大部分保留。相机 JPEG 验证中也没有出现明显的全面改善。附加混合图层的效果较轻，不能把它当成已经完成去斑、去黑头。
4. **1197 的唇缘没有在本轮得到新的唇色处理。** 本轮局部修复受皮肤蒙版约束，嘴唇独立保留；PSGAN / 专门的唇色路线尚未运行。

## 对比条件与边界

- 修复主对比以同一张 0.4.2 JPEG 为输入，属于在现有结果上增量处理；另外保存相机 JPEG 验证，避免把已有调色结果的输入分布当作唯一测试条件。
- 修复裁切采用原有 Vision 人脸框的 1.5 倍方形区域。复用发布者 `retouch_local`、`predict_roi` 的方法体；替换了框架加载与人脸检测入口，关闭额外美白，并增加当前皮肤蒙版约束。因此这些是可复现的适配实验，不是原论文指标复现。
- 当前模型包装器默认 `retouch_local=False`；本轮明确启用局部修复。原始网络权重没有重训或修改。
- 所有分割对比使用同一份相机 JPEG，显示时统一使用同一裁切。Sapiens2 的主人物框仅复用旧人物蒙版定位，未把旧轮廓乘回新预测。
- 运行时间是本机单次前向／局部处理记录，首次编译、模型加载、解码与输出开销不同，不是系统性能基准。具体值见运行时间汇总。
- 没有完整人工像素标注或成对修图真值，未计算或声称 F1、IoU、PSNR、SSIM；色彩差和改动面积也不能代替人眼对瑕疵的判断。

## 校验

官方来源的五个权重文件均核对发布者 SHA-256；全部网络严格匹配参数。运行时检查输出有限、零权重皮肤蒙版区域保持原像素，并核对相机 ARW/JPEG。另对 ModelScope 372 做 CPU/MPS 数值核验，对 Sapiens2 1063 做 FP16/FP32 类别核验，详见数值与原片核验。

## 数据集与后续训练

本轮没有下载完整训练集，也没有训练。已确认可供下一阶段选择的资料：

| 数据 | 用途 | 官方入口 |
|---|---|---|
| FFHQR / 原 FFHQ | 配对专业修饰人脸，约7万张、1024×1024；适合瑕疵修复训练 | https://github.com/skylab-tech/ffhqr-dataset |
| CelebAMask-HQ | 3万张、19类人脸部位标注 | https://github.com/switchablenorms/CelebAMask-HQ |
| LaPa | 2.2万余张、11类像素标注与106点关键点 | https://github.com/jd-opensource/lapa-dataset |
| ACNE04-v2 | 1204张、32443处痘类位置标注；没有修复后真值 | https://github.com/AIpourlapeau/acne04v2 |
| PPR10K | 11161张、三位修图师目标与人物蒙版；适合整体色彩与组内一致性 | https://github.com/csjliang/PPR10K |

这些数据有各自的使用条件，不能用代码许可证替代数据或权重的许可。

## 尚未运行的候选

RetouchFormer 的官方百度网盘入口可列出 `gen_best.pth`，但未成功取得权重；随后浏览器站点安全策略阻止了官方页面访问，已停止这一路访问。未将其他模型的结果标成 RetouchFormer 结果。官方项目：https://github.com/Davidcoach/RetouchFormer_AAAI_24

## 复现入口

脚本位于 `Scripts/portrait-research/`，环境与源代码位于 `.build/portrait-research-2026-11-12/`。模型来源、源代码提交、权重校验与依赖已随结果保存。正式应用仍为0.4.2，未把实验模型打包到应用。
'''
    (OUTPUT/'实验记录.md').write_text(report)


def main():
    OUTPUT.mkdir(parents=True,exist_ok=True)
    for stem in ['DSC00372','DSC01197']:
        retouch_board(stem)
    mask_board()
    summary()
    print(OUTPUT)


if __name__=='__main__':
    main()
