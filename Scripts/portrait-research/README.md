# 开源算法独立实验

本目录仅运行和比较研究模型，不修改正式 Swift 处理链。默认工作目录为项目根目录，固定使用本轮 `.build/portrait-research-2026-11-12/` 环境、权重与第三方源码。

输出位于 `成片/开源算法对比-2026-11-12/`，结论、对比条件和未运行的候选见其中的 `实验记录.md`。本轮没有训练模型或下载完整训练数据集。

## 已准备的环境与来源

- Python 3.12.16、PyTorch 2.8.0、torchvision 0.23.0；全部依赖锁定位于结果目录 `Python依赖锁定.txt`。
- 第三方源码：`.build/portrait-research-2026-11-12/repos/{SegFace,sapiens2,modelscope,RetouchFormer}`。准确提交见结果目录 `模型来源与校验.json` 的 `sources`。
- 五个权重文件全部按官方 SHA-256 校验，路径、下载来源及版本见上述清单。`fetch_models.py --root .build/portrait-research-2026-11-12` 可校验缓存、补充下载；重新从远端解析版本时必须对照已保存清单，避免把后续发布版本混入本次结果。
- ModelScope 模型包装器保存在工作目录的 `modelscope-wrapper.py`，来源为 `https://modelscope.cn/models/iic/cv_unet_skin_retouching_torch/resolve/master/ms_wrapper.py`，SHA-256 为 `592c9941594c285f23ff25a9d0d5535e5a433d3e42c334301b41d147a5b25c12`。实验提取该文件原有的两个推理方法体，替换框架加载和人脸框入口。
- 人脸框复用 `.build/cross-group-qa/<照片>/faces.json`，由原有 Vision 分析产生。当前语义蒙版由 `ReferenceMasks` 在本轮重新输出到工作目录 `current-masks/`。

## 复现本轮推理

```sh
.build/portrait-research-2026-11-12/venv/bin/python -B Scripts/portrait-research/segment.py --model segface-mobile --stems DSC01063 DSC00372 DSC01197
.build/portrait-research-2026-11-12/venv/bin/python -B Scripts/portrait-research/segment.py --model segface-swin --stems DSC01063 DSC00372 DSC01197
.build/portrait-research-2026-11-12/venv/bin/python -B Scripts/portrait-research/segment.py --model sapiens2 --stems DSC01063 DSC00372 DSC01197
.build/portrait-research-2026-11-12/venv/bin/python -B Scripts/portrait-research/segment.py --model sapiens2 --precision fp32 --stems DSC01063
.build/portrait-research-2026-11-12/venv/bin/python -B Scripts/portrait-research/retouch.py --stems DSC00372 DSC01197
.build/portrait-research-2026-11-12/venv/bin/python -B Scripts/portrait-research/retouch.py --input-kind camera --stems DSC00372 DSC01197
.build/portrait-research-2026-11-12/venv/bin/python -B Scripts/portrait-research/retouch.py --device cpu --stems DSC00372
.build/portrait-research-2026-11-12/venv/bin/python -B Scripts/portrait-research/verify.py
.build/portrait-research-2026-11-12/venv/bin/python -B Scripts/portrait-research/report.py
```

在 16GB Mac 上逐条运行。运行记录中的时间包含各自方法体及同步，不包含完整应用的加载、预览和导出过程；不能直接作为应用延迟承诺。

`retouch.py` 同时保留未约束局部预测和当前皮肤蒙版约束版本。零蒙版区域按原像素合成；JPEG 编码本身有损，精确数值对比使用 PNG 局部结果。

`verify.py` 检查严格权重匹配后的输出、发布者 SHA-256、源文件完整性、类别图尺寸，以及 CPU/MPS 和 FP16/FP32 的一致性。没有完整人工真值，因此这些校验不代表分割或瑕疵识别准确率。

RetouchFormer 未运行：官方百度网盘访问被浏览器站点安全策略阻止。没有将其他模型的输出冒充该模型，实验脚本也不尝试绕过限制。
