#!/usr/bin/env python3
"""Check source integrity and numerical consistency, without claiming accuracy."""
import json
from pathlib import Path

import numpy as np
from PIL import Image

from common import PROJECT, ROOT, OUTPUT, digest, save_json, read_srgb


def main():
    metrics = {}
    folder = OUTPUT/'瑕疵/DSC00372'
    for name in ['局部修复','局部修复加柔化-0.35','局部修复加柔化-0.70']:
        with Image.open(folder/'CPU核验'/(name+'-皮肤约束局部.png')) as image:
            cpu = np.asarray(image).astype(np.int16)
        with Image.open(folder/(name+'-皮肤约束局部.png')) as image:
            mps = np.asarray(image).astype(np.int16)
        difference = np.abs(cpu-mps)
        mean = float(difference.mean())
        large = float((difference.max(2)>1).mean())
        assert mean < .1 and large < .001, 'CPU/MPS 数值差异过大'
        metrics[name] = dict(cpu_mps_mean_abs_rgb=mean,
            cpu_mps_max_abs_rgb=int(difference.max()),fraction_over_1=large)
    folder = OUTPUT/'选区/DSC01063'
    with Image.open(folder/'sapiens2-fp32/类别.png') as image:
        fp32 = np.asarray(image)
    with Image.open(folder/'sapiens2/类别.png') as image:
        fp16 = np.asarray(image)
    disagreement = float((fp32!=fp16).mean())
    assert disagreement < .01, 'FP16/FP32 类别差异过大'
    metrics['Sapiens2精度核验'] = dict(class_disagreement_fraction=disagreement)
    integrity = {}
    previous = json.loads((PROJECT/'.build/feedback-qa-2026-11-12/原片SHA256.json').read_text())
    for path,expected in previous.items():
        actual = digest(path)
        assert actual == expected, '原始 ARW 校验失败：'+path
        integrity[Path(path).name] = dict(sha256=actual,matches_previous=True)
    for path in (OUTPUT/'选区').rglob('运行记录.json'):
        record = json.loads(path.read_text())
        actual = digest(record['source'])
        assert actual == record['source_sha256'], '相机 JPEG 校验失败'
        integrity[path.parents[1].name+'.JPG'] = dict(sha256=actual,matches_inference_input=True)
        with Image.open(path.parent/'类别.png') as image:
            classes = np.asarray(image)
        image = read_srgb(record['source'])
        assert classes.shape == (image.height,image.width), '类别图必须匹配应用 EXIF 方向后的像素尺寸'
        assert int(classes.max()) < len(record['labels'])
    for path in (OUTPUT/'瑕疵').rglob('运行记录.json'):
        record = json.loads(path.read_text())
        assert digest(record['source']) == record['source_sha256']
        assert all(variant['outside_zero_mask_max_delta']==0 for variant in record['variants'])
    model_manifest = json.loads((ROOT/'model-manifest.json').read_text())
    for record in model_manifest['models']:
        assert record['verified'] and digest(record['path']) == record['sha256']
    save_json(dict(numerics=metrics,sources=integrity,checks_passed=True),OUTPUT/'数值与原片核验.json')
    print('原片、模型权重、类别尺寸、蒙版外保护与数值一致性核验通过。')


if __name__=='__main__':
    main()
