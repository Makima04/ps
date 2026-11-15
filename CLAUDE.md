# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概览

「调色工作室」：原生 macOS 人像调色应用（Swift 5.10 / SwiftUI / Core Image / Metal / Vision / Core ML），要求 macOS 14+。SwiftPM 包，无 Xcode 工程。`README.md` 是功能与验收的权威文档（中文），记录了各版本的参数决策与样片量化指标，改动调色行为前先读对应章节。界面文案、错误信息、文档均用中文。

## 常用命令

本环境的 SwiftPM manifest 沙箱不可用，**所有 swift build/run/test 都要加 `--disable-sandbox`**。

```sh
# 构建并打包应用（先准备模型 → release 构建 Ps → 组装 .app → ad-hoc 签名）
./Scripts/build-app.sh                 # 输出 .build/调色工作室.app
./Scripts/build-app.sh /path/新名字.app  # 旧版正在运行时务必传新路径，避免覆盖运行中的包
open .build/调色工作室.app

swift run --disable-sandbox Ps         # 开发运行
swift test --disable-sandbox           # 全部测试
swift test --disable-sandbox --filter ColorEngineTests/testName   # 单个测试
swift test --disable-sandbox --filter 'AutomaticBaseTests|StudioTests'  # 也支持正则

# 首次独立构建前准备 Core ML 模型（从 HuggingFace 下载固定 revision、校验 SHA-256、
# 编译到 Sources/ColorEngine/Models/*.mlmodelc；之后复用，build-app.sh 会自动执行）
python3 Scripts/prepare-models.py
```

照片验收测试在没有环境变量时 `XCTSkip`，不是失败：

```sh
PS_TEST_PHOTO_DIR="$PWD/PhotoLibrary/测试组/2025-09-29/JPEG" \
PS_REFERENCE_PHOTO="$PWD/PhotoLibrary/参考/单图追色/奶油肤色参考.png" \
PS_QA_OUTPUT="$PWD/.build/portrait-workflow-qa" \
swift test --disable-sandbox --filter PortraitWorkflowTests
```

`PS_QA_OUTPUT` 会输出蒙版、预览、模板 JSON 和全尺寸 16 位 TIFF 供人工检查——自动测试不代替看图。`PS_PROJECT_FILE` 可让应用使用独立项目 JSON，避免污染日常项目。

参考图库的 Python 工具用独立 venv（`numpy`/`Pillow`，见 `Scripts/requirements-reference.txt`）：

```sh
python3 -m venv .build/reference-analysis-env
.build/reference-analysis-env/bin/python -m pip install -r Scripts/requirements-reference.txt
.build/reference-analysis-env/bin/python -m unittest discover -s Tests -p 'ReferenceLibraryTests.py'
```

## 架构

一个共享库 + 五个可执行目标（见 `Package.swift`）：

- **ColorEngine**（库）：全部图像处理逻辑，`actor ColorEngine` 是唯一入口。模型以 `.copy("Models")` 资源打包，运行时经 `Bundle.module` 加载。
- **Ps**（SwiftUI 应用）：`Studio`（@MainActor ObservableObject）持有 `Project`（照片 + 自定义预设 + 肤色模板），变更后 300ms 防抖自动保存到 `~/Library/Application Support/PsColorStudio/project.json`。撤销用 `UndoManager`（40 级）。preview / export / reference 各用独立的 ColorEngine actor。
- **PortraitRetouch / ReferenceMatch / ReferenceMasks / PhotoCatalog**：复用 ColorEngine 的命令行工具，用法见 README。

### 双文件像素源（PhotoSource）

核心设计：同名 ARW+JPEG 配对时，**RAW 供像素**（CIRAWFilter 全尺寸显影，关草稿模式，14 位线性、Display P3、高光余量大），**相机 JPEG 供分析**（Vision 人脸 / Core ML 语义蒙版需要 gamma 图像，线性 RAW 太灰检测不稳）并供 EXIF/DPI 元数据。`PhotoSource.resolve` 会先解析符号链接（PhotoLibrary 目录里全是链接）。`preferRAW: false` 强制纯 JPEG 路径。**参考肤色模板图例外：始终读所选成片本身，不升级到 RAW。**

### 合成管线（ColorEngine.composite）

固定顺序：**手动瑕疵修复 → 自动基础校正（可选）→ 全图基础调色 → 调整图层（列表自下而上）→ 脸部参考肤色适配 → 身体肤色协调**。预览与全尺寸导出走同一链条、同一算子，改动任何一环必须保持两者一致（有专门回归测试）。

工作空间为扩展线性 Display P3 + 32 位浮点 CIContext（Metal）。预览 8 位；TIFF 导出 16 位 LZW；JPEG 0.96 质量、透明合成白底。导出先写临时文件再移动，绝不动原图；重名自动追加编号。

### 蒙版（MaskRenderer + SemanticParser）

Vision（人物/人脸/关键点/手部）+ FaceParsing、ClothSegmentation 两个 Core ML 模型。语义结果按 `(url, size, mtime)` 内存缓存，最多 2 份，淘汰时联动清除 body/hand 引导缓存。蒙版后处理顺序固定：**画笔修正 → 反相 → 羽化（相对原图长边，预览导出同比例）→ 高光保护 → 不透明度**。人脸按画面从左到右编号（不跨照片认人），`FaceMaskOwnership` 做逐人隔离；`MaskBounds` 限制局部选区采样范围，防止边缘延伸条带污染统计。额头/脸颊/眼下/鼻侧是由双眼关键点推导的柔边解剖引导区，与语义皮肤相交，可为空。

### 肤色数学（SkinColorMath / SkinReference / SkinProcessing / AutomaticBase）

统一在线性 P3 中转 CIELAB D65 再比较，不直接比不同 ICC 空间的 RGB。追色 = 单调明度曲线 + 限幅 a*/b* 偏移；每次适配后实测合成像素，高光溢出增长 >0.005或 p10–p90 明度跨度缩到 80% 以下就把强度减半重试（最多 4 轮），仍不达标则保留原效果并写入警告报告。

`AutomaticBase` 的 EV 是**色调曲线补偿量**（`y·g/(1+y·(g−1))`，保黑白端点、扩展高光仍 >1），Metal kernel 只改 Lab L*、保留实测色度——不是线性曝光放大，否则暗部强提会把粉色衣服提成饱和红。偏色校正默认关，需足够中性色样本（≥max(150, 总数/100)），限幅 a*±2 / b*±3。

身体协调仅限单人照片：目标取自**本张处理后的脸**（不是外部参考图），只提亮比脸暗超过 3 L* 的区域，天然受光的亮皮肤不压暗；a* 容差 [脸−4.5, 脸+1.5]、b*±1.5，单次上限 10 L*/10 色彩。身体候选 = 主脸 Lab 色差 ∩ 人物蒙版 ∩ 姿态肢体走廊 ∩ ¬服装 ∩ ¬头部，再并上 Vision 手部关键点约束的宽容差手部皮肤。候选是估计值，靠画笔修正。

Metal 算子是运行时从字符串编译的 stitchable kernel（共用 `SkinProcessing.colorHelpers` 前缀），需要 GPU 支持动态库。

### 数据兼容与归属（改模型字段前必读）

- `Adjustments`/`ColorAdjustments` 用手写 Codable 维持**旧版扁平 JSON**（全图参数在顶层），新字段一律 `decodeIfPresent` + 默认值，旧项目必须能直接读取（`Project.version == 1`）。新增开关类功能默认关闭，保持旧项目行为不变。
- 画笔修正、手动修复点是**每张照片**的数据；自定义预设只存自动选区类型和调色参数，不带坐标。
- 「同步到全部照片」复制参数与图层结构，蒙版按每张重新生成，但保留接收照片在同一图层 ID / 同一模板下自己的画笔修正和修复点。
- 参考模板库存的是目标快照，编辑模板库不影响已应用照片，需重新应用。

## 数据目录

- `100MSDCF/`：相机原片（ARW+JPEG）；`PhotoLibrary/`：PhotoCatalog 按日期生成的符号链接目录与成片；`博主参考图库/`：按帖子保存的参考图与分析。三者都在 .gitignore 中，体积大，不要遍历或提交。
- 测试样片固定在 `PhotoLibrary/测试组/2025-09-29/{JPEG,RAW}`；`Scripts/skin-metrics.py` 等 Python 脚本用于量化肤色指标（L*/C*/h°/ITA°），README 中的验收表格由它产出。
- 应用版本号在 `Scripts/build-app.sh` 生成的 Info.plist 里（`CFBundleShortVersionString`），不在 Package.swift。
