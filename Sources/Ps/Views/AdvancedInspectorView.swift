import ColorEngine
import SwiftUI

struct PresetsAndLayersSidebar: View {
    @ObservedObject var studio: Studio
    @Binding var showingPresetName: Bool
    @Binding var presetName: String

    private var settings: Adjustments { studio.photo?.settings ?? Adjustments() }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("调色预设").font(.headline)
                Spacer()
                Button {
                    presetName = ""
                    showingPresetName = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("将当前调色保存为预设")
                .disabled(studio.photo == nil)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(studio.presets) { preset in
                        Button {
                            studio.setAdjustments(preset.settings)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: preset.name == "原始色彩" ? "circle" : "circle.lefthalf.filled")
                                    .font(.system(size: 16))
                                    .foregroundStyle(studioAccent.opacity(0.8))
                                Text(preset.name)
                                    .font(.system(size: 12, weight: .medium))
                                Spacer(minLength: 0)
                                if studio.photo != nil && settings == preset.settings {
                                    Image(systemName: "checkmark").foregroundStyle(studioAccent)
                                }
                            }
                            .padding(12)
                            .background(settings == preset.settings && studio.photo != nil ? studioAccent.opacity(0.10) : Color.white.opacity(0.035))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .disabled(studio.photo == nil)
                    }
                }
            }
            Divider()
            layerPanel
            Button(action: studio.syncAll) {
                Label("同步到全部照片", systemImage: "rectangle.stack")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(studio.project.photos.count < 2)
        }
        .padding(18)
        .background(studioPanel)
    }

    private var layerPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("调整图层").font(.headline)
                Spacer()
                Menu {
                    ForEach(MaskKind.allCases) { mask in
                        Button(mask.label + "调整") { studio.addLayer(mask: mask) }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("添加调整图层")
                .disabled(studio.photo == nil)
            }
            Button("人物提亮＋高光保护", action: studio.addPortraitLayers)
                .font(.system(size: 11))
                .buttonStyle(.bordered)
                .disabled(studio.photo == nil)
            Button("皮肤与服装分开调色", action: studio.addSkinAndClothingLayers)
                .font(.system(size: 11))
                .buttonStyle(.bordered)
                .disabled(studio.photo == nil)
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(Array(settings.layers.reversed())) { layer in
                        HStack(spacing: 7) {
                            Button { studio.toggleLayer(layer.id) } label: {
                                Image(systemName: layer.enabled ? "eye" : "eye.slash")
                                    .frame(width: 18)
                            }
                            .buttonStyle(.plain)
                            .help(layer.enabled ? "隐藏图层" : "显示图层")
                            Button { studio.activeLayerID = layer.id } label: {
                                HStack {
                                    Text(layer.name).lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text(layer.mask.label)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .font(.system(size: 12))
                        .padding(9)
                        .background(studio.activeLayerID == layer.id ? studioAccent.opacity(0.12) : Color.white.opacity(0.035))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    Button {
                        studio.activeLayerID = nil
                        studio.referenceMaskEditing = false
                        studio.showMask = false
                    } label: {
                        HStack {
                            Image(systemName: "photo")
                            Text("基础调色")
                            Spacer()
                        }
                        .font(.system(size: 12))
                        .padding(9)
                        .background(studio.activeLayerID == nil ? studioAccent.opacity(0.12) : Color.white.opacity(0.035))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(studio.photo == nil)
                }
            }
            .frame(minHeight: 100, maxHeight: 230)
            HStack {
                Button { studio.moveLayer(up: true) } label: {
                    Image(systemName: "arrow.up")
                }.help("向上移动，稍后叠加")
                Button { studio.moveLayer(up: false) } label: {
                    Image(systemName: "arrow.down")
                }.help("向下移动，提前叠加")
                Spacer()
                Button(role: .destructive, action: studio.removeLayer) {
                    Image(systemName: "trash")
                }.help("删除调整图层")
            }
            .buttonStyle(.plain)
            .disabled(studio.activeLayer == nil)
        }
    }
}

struct AdvancedInspectorView: View {
    @ObservedObject var studio: Studio
    @Binding var showOriginal: Bool
    @Binding var showingBlemishReview: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text(studio.activeLayer?.name ?? "基础调色").font(.headline).lineLimit(1)
                    Spacer()
                    Button("重置") { studio.setColor(ColorAdjustments()) }
                        .font(.system(size: 11))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                if studio.activeLayer != nil {
                    maskControls
                    Divider()
                }
                AutomaticBaseControls(studio: studio)
                Divider()
                RepairControls(studio: studio, showOriginal: $showOriginal)
                Divider()
                BlemishControls(studio: studio, isExpanded: $showingBlemishReview)
                Divider()
                ReferenceControls(studio: studio)
                Divider()
                VStack(spacing: 18) {
                    adjustment("曝光", key: \.exposure, range: -3...3, suffix: " EV")
                    adjustment("色温", key: \.temperature, range: -2000...2000, precision: 0)
                    adjustment("色调", key: \.tint, range: -50...50, precision: 0)
                }
                Divider()
                VStack(spacing: 18) {
                    adjustment("高光", key: \.highlights, range: -1...0)
                    adjustment("阴影", key: \.shadows, range: 0...1)
                    adjustment("对比度", key: \.contrast, range: -0.5...0.5)
                    adjustment("曲线 · S 强度", key: \.curve, range: -0.10...0.10)
                    adjustment("饱和度", key: \.saturation, range: -1...0.5)
                    if studio.activeLayer?.mask.isSkinRegion == true {
                        Text("肤色与纹理").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                        adjustment("白皙程度", key: \.skinWhitening, range: 0...1)
                        adjustment("减少黄感", key: \.skinYellowReduction, range: 0...1)
                        adjustment("肤色均匀度", key: \.skinUniformity, range: 0...1)
                        adjustment("血色保留", key: \.skinVitality, range: 0...1)
                        adjustment("脸颊红润", key: \.cheekBlush, range: -1...1)
                        adjustment("压低泛红", key: \.rednessReduction, range: 0...1)
                        adjustment("皮肤柔化", key: \.skinSmoothing, range: 0...1)
                        adjustment("纹理保留", key: \.texturePreservation, range: 0...1)
                        adjustment("细节回补", key: \.skinDetail, range: 0...1)
                        adjustment("边缘保护", key: \.skinEdgeGuard, range: 0...1)
                        Text("均匀度与柔化不判断痘、痣或雀斑。细节回补用于补回柔化和提亮后的纹理；边缘保护避免白皙和去黄越过发丝、鼻翼和唇缘。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if studio.activeLayer?.mask == .lips {
                        Picker("唇色模式", selection: Binding(get: { studio.editableColor.lipStyle }, set: { value in
                            var color = studio.editableColor
                            color.lipStyle = value
                            studio.setColor(color)
                        })) {
                            ForEach(LipStyle.allCases) { style in Text(style.label).tag(style) }
                        }
                        if studio.editableColor.lipStyle != .manual {
                            adjustment("自动协调强度", key: \.lipAdaptation, range: 0...1)
                        }
                        if studio.editableColor.lipStyle == .reference {
                            Button("将所选参考模板用于唇色", action: studio.useSelectedLipTemplate)
                                .disabled(studio.selectedSkinTemplate?.lips == nil)
                            if let template = studio.activeLayer?.lipReference {
                                Text("独立唇色参考：\(template.name)").font(.system(size: 11))
                                Button("改用肤色模板中的唇色") { studio.updateLayer { $0.lipReference = nil } }
                            }
                        }
                        adjustment("唇部明亮度", key: \.lipBrightness, range: -1...1)
                        adjustment("唇色偏移 · 粉／珊瑚", key: \.lipHue, range: -1...1)
                        adjustment("唇色浓淡", key: \.lipChroma, range: -1...1)
                        adjustment("唇纹柔化", key: \.lipSmoothing, range: 0...1)
                        Text("自动模式按最终肤色逐人计算；亮度、颜色与唇纹分别控制，保护唇缘和高光。唇色可独立使用所选参考，不改变肤色目标。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        if studio.editableColor.lipStyle == .reference && studio.activeLayer?.lipReference?.lips == nil && studio.photo?.settings.skinReference?.template.lips == nil {
                            Text("当前模板没有唇色特征，请重新导入参考图并应用模板。")
                                .font(.system(size: 11)).foregroundStyle(.orange)
                        }
                        DisclosureGroup("旧版唇部控制") {
                            adjustment("唇部优化", key: \.lipPolish, range: 0...1)
                            adjustment("唇色自然化", key: \.lipNaturalization, range: 0...1)
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("导出设置").font(.headline)
                    Picker("格式", selection: $studio.format) {
                        ForEach(OutputFormat.allCases) { format in
                            Text(format.label).tag(format)
                        }
                    }
                    .labelsHidden()
                    Picker("色彩", selection: $studio.profile) {
                        ForEach(OutputProfile.allCases) { profile in
                            Text(profile.label).tag(profile)
                        }
                    }
                    .labelsHidden()
                    Text("保持原图像素尺寸 · 独立保存成片")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(studio.format == .tiff ? "TIFF 使用 LZW 无损压缩" : "JPEG 使用 96% 品质编码")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button {
                        studio.export(all: true)
                    } label: {
                        Text("导出全部 · \(studio.project.photos.count) 张")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(studio.exporting)
                    if studio.exporting {
                        Button("取消导出", action: studio.cancelExport)
                            .font(.system(size: 12))
                    }
                }
            }
            .padding(20)
            .disabled(studio.photo == nil)
        }
        .background(studioPanel)
        .task(id: studio.photo?.id) { await studio.detectFaces() }
    }

    private func layerBinding<Value>(_ key: WritableKeyPath<AdjustmentLayer, Value>,
                                     default fallback: Value) -> Binding<Value> {
        Binding(get: { studio.activeLayer?[keyPath: key] ?? fallback },
                set: { value in studio.updateLayer { $0[keyPath: key] = value } })
    }

    private var maskControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("图层名称", text: layerBinding(\.name, default: ""))
                .textFieldStyle(.roundedBorder)
            Picker("区域", selection: Binding(
                get: { studio.activeLayer?.mask ?? .all },
                set: { mask in
                    studio.updateLayer {
                        $0.mask = mask
                        let defaults = AdjustmentLayer(mask: mask)
                        $0.rangeStart = defaults.rangeStart
                        $0.rangeEnd = defaults.rangeEnd
                    }
                }
            )) {
                ForEach(MaskKind.allCases) { mask in Text(mask.label).tag(mask) }
            }
            if studio.activeLayer?.mask.isFaceRegion == true {
                Picker("人物", selection: layerBinding(\.faceIndex, default: nil)) {
                    Text("全部人物").tag(nil as Int?)
                    ForEach(studio.detectedFaces) { face in
                        Text("人物 \(face.index + 1) · 从画面左侧起").tag(Optional(face.index))
                    }
                }
                Button("重新识别人物") { Task { await studio.detectFaces() } }
                    .font(.system(size: 11))
            }
            if studio.activeLayer?.mask == .bodySkin || studio.activeLayer?.mask == .teeth {
                Text("候选选区可能漏选或误选，请查看蒙版并用画笔修正。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Picker("混合", selection: layerBinding(\.blendMode, default: .normal)) {
                ForEach(LayerBlendMode.allCases) { mode in Text(mode.label).tag(mode) }
            }
            Picker("画笔", selection: $studio.brushTool) {
                ForEach(MaskBrushTool.allCases) { tool in Text(tool.label).tag(tool) }
            }
            .pickerStyle(.segmented)
            if studio.brushTool != .inspect {
                HStack {
                    Text("画笔大小")
                    Slider(value: $studio.brushRadius, in: 0.001...0.05)
                        .accessibilityLabel("画笔大小")
                }
                Text("拖动涂画 · Option 临时擦除 · Command＋滚轮缩放")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if !(studio.activeLayer?.brushStrokes ?? []).isEmpty {
                Button("清除当前图层的画笔修正", action: studio.clearBrushStrokes)
                    .font(.system(size: 11))
            }
            Toggle("启用图层", isOn: layerBinding(\.enabled, default: true))
            Toggle("反相蒙版", isOn: layerBinding(\.inverted, default: false))
            maskSlider("不透明度", key: \.opacity, range: 0...1)
            maskSlider("羽化 · 长边比例", key: \.feather, range: 0...0.01)
            maskSlider("高光保护", key: \.highlightProtection, range: 0...1)
            if studio.activeLayer?.mask == .highlights || studio.activeLayer?.mask == .shadows {
                maskSlider("亮度过渡起点", key: \.rangeStart,
                           range: 0...max(0, (studio.activeLayer?.rangeEnd ?? 1) - 0.01))
                maskSlider("亮度过渡终点", key: \.rangeEnd,
                           range: min(1, (studio.activeLayer?.rangeStart ?? 0) + 0.01)...1)
            }
        }
        .font(.system(size: 12))
    }

    private func maskSlider(_ title: String, key: WritableKeyPath<AdjustmentLayer, Double>,
                            range: ClosedRange<Double>) -> some View {
        let value = layerBinding(key, default: 0)
        return VStack(spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.1f%%", value.wrappedValue * 100))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .controlSize(.small)
                .accessibilityLabel(title)
        }
    }

    private func adjustment(_ title: String, key: WritableKeyPath<ColorAdjustments, Double>,
                            range: ClosedRange<Double>, precision: Int = 2, suffix: String = "") -> some View {
        let binding = Binding<Double>(
            get: { studio.editableColor[keyPath: key] },
            set: { value in
                var updated = studio.editableColor
                updated[keyPath: key] = value
                studio.setColor(updated)
            }
        )
        return VStack(spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Text(String(format: "%+.\(precision)f", binding.wrappedValue) + suffix)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .onTapGesture(count: 2) { binding.wrappedValue = key == \.texturePreservation ? 0.75 : 0 }
            }
            Slider(value: binding, in: range)
                .controlSize(.small)
                .accessibilityLabel(title)
        }
    }
}
