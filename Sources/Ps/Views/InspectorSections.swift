import ColorEngine
import SwiftUI

struct AutomaticBaseControls: View {
    @ObservedObject var studio: Studio

    var body: some View {
        DisclosureGroup("自动基础校正") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("逐张自适应曝光", isOn: Binding(get: { studio.photo?.settings.automaticBase != nil },
                    set: { enabled in if enabled { studio.enableAutomaticBase(all: false) } else { studio.removeAutomaticBase() } }))
                if let automatic = studio.photo?.settings.automaticBase {
                    Text(String(format: "校正强度 %.0f%%", automatic.strength * 100))
                    Slider(value: Binding(get: { studio.photo?.settings.automaticBase?.strength ?? 1 },
                        set: { value in studio.updateAutomaticBase { $0.strength = value } }), in: 0...1)
                        .accessibilityLabel("自动校正强度")
                    Text(String(format: "脸部基础亮度 %.0f", automatic.targetFaceLightness))
                    Slider(value: Binding(get: { studio.photo?.settings.automaticBase?.targetFaceLightness ?? 53 },
                        set: { value in studio.updateAutomaticBase { $0.targetFaceLightness = value } }), in: 35...65)
                        .accessibilityLabel("脸部基础亮度")
                    Toggle("依据中性色轻微校正偏色", isOn: Binding(get: { studio.photo?.settings.automaticBase?.correctColorCast ?? false },
                        set: { value in studio.updateAutomaticBase { $0.correctColorCast = value } }))
                    Button("逐张启用全部照片") { studio.enableAutomaticBase(all: true) }
                        .disabled(studio.project.photos.count < 2)
                }
                Button("分析校正建议", action: studio.checkAutomaticBase).disabled(studio.referenceBusy)
                Text("自动校正在手动调色之前执行；限制全图提亮，并为偏暗人物补光。仍可手动微调曝光和白平衡。")
                    .foregroundStyle(.secondary)
                if !studio.automaticBaseReportText.isEmpty { Text(studio.automaticBaseReportText).foregroundStyle(.secondary) }
            }.font(.system(size: 11)).padding(.top, 10)
        }.font(.system(size: 12, weight: .medium))
    }
}

struct BlemishControls: View {
    @ObservedObject var studio: Studio
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup("检查局部细节", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Button("分析本张照片", action: studio.analyzeBlemishes).disabled(studio.blemishBusy)
                if studio.blemishBusy { ProgressView().controlSize(.small) }
                Text("检测灵敏度")
                Slider(value: $studio.blemishSensitivity, in: 0...1)
                    .disabled(studio.blemishBusy)
                    .onChange(of: studio.blemishSensitivity) { _, _ in studio.clearBlemishAnalysis() }
                Text("逐张定位小红点、深色点与黄褐色小点，并寻找附近干净取样区。候选不等于痘：痣、雀斑、妆容需人工判断；深色及黄褐色点需确认后勾选。")
                    .foregroundStyle(.secondary)
                if !studio.blemishWarnings.isEmpty { Text(studio.blemishWarnings).foregroundStyle(.secondary) }
                if !studio.blemishCandidates.isEmpty {
                    Toggle("显示候选位置与编号", isOn: $studio.showBlemishCandidates)
                    HStack {
                        Button("选中高分红点", action: studio.selectRecommendedBlemishes)
                        Button("全部不选") { studio.selectedBlemishIDs = [] }
                    }
                    ForEach(Array(studio.blemishCandidates.enumerated()), id: \.element.id) { index, candidate in
                        HStack(alignment: .top, spacing: 6) {
                            Toggle("", isOn: Binding(get: { studio.selectedBlemishIDs.contains(candidate.id) }, set: { selected in
                                if selected { studio.selectedBlemishIDs.insert(candidate.id) }
                                else { studio.selectedBlemishIDs.remove(candidate.id) }
                            })).labelsHidden().disabled(candidate.repair == nil)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(index + 1). \(candidate.kind.label)")
                                Text("人物 \(candidate.faceIndex + 1) · 评分 \(Int(candidate.score * 100))\(candidate.repair == nil ? " · 无干净取样区" : "")")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Button("定位") { studio.showBlemishCandidates = true; studio.focusedBlemishID = candidate.id }
                            Button("排除") { studio.excludeBlemish(candidate.id) }
                        }
                    }
                    Button("修复所选 \(studio.selectedBlemishIDs.count) 处", action: studio.applySelectedBlemishes)
                        .disabled(studio.selectedBlemishIDs.isEmpty || studio.blemishBusy)
                    Text("仅应用勾选的候选；可撤销。候选和取样点按本张照片重新计算，不随预设或同步复制。")
                        .foregroundStyle(.secondary)
                }
            }.font(.system(size: 11)).padding(.top, 10)
        }.font(.system(size: 12, weight: .medium))
    }
}

struct RepairControls: View {
    @ObservedObject var studio: Studio
    @Binding var showOriginal: Bool

    var body: some View {
        DisclosureGroup("手动小瑕疵修复") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("修复点按模式", isOn: $studio.repairMode)
                    .onChange(of: studio.repairMode) { _, enabled in
                        if enabled { studio.showMask = false; showOriginal = false }
                    }
                Slider(value: $studio.repairRadius, in: 0.0005...0.015)
                    .accessibilityLabel("修复半径")
                Text("先点干净皮肤取样，再点小瑕疵。Option 点按重新取样。保留目标处光影，使用取样处纹理。")
                    .foregroundStyle(.secondary)
                Text("已修复 \(studio.photo?.settings.repairSpots?.count ?? 0) 处 · 修复点仅保存在当前照片")
                if !(studio.photo?.settings.repairSpots ?? []).isEmpty {
                    Button("清除本张修复点", action: studio.clearRepairSpots)
                }
            }.font(.system(size: 11)).padding(.top, 10)
        }.font(.system(size: 12, weight: .medium))
    }
}

struct ReferenceControls: View {
    @ObservedObject var studio: Studio

    var body: some View {
        DisclosureGroup("参考肤色模板") {
            VStack(alignment: .leading, spacing: 12) {
                Button(action: studio.pickSkinReference) {
                    Label("导入参考图／模板", systemImage: "photo.badge.plus")
                }.disabled(studio.referenceBusy)
                if studio.referenceBusy { ProgressView().controlSize(.small) }
                Picker("模板", selection: $studio.selectedSkinTemplateID) {
                    Text("选择参考模板").tag(nil as UUID?)
                    ForEach(studio.skinTemplates) { template in Text(template.name).tag(Optional(template.id)) }
                }.labelsHidden()
                if let template = studio.selectedSkinTemplate {
                    TextField("模板名称", text: Binding(get: { studio.selectedSkinTemplate?.name ?? "" },
                        set: { name in studio.updateSkinTemplate { $0.name = name } }))
                    TextField("场景分组", text: Binding(get: { studio.selectedSkinTemplate?.scene ?? "" },
                        set: { scene in studio.updateSkinTemplate { $0.scene = scene } }))
                    referenceTarget("目标亮度 L*", key: \.targetLightness, range: 15...95)
                    referenceTarget("目标红润 a*", key: \.targetRed, range: -30...50)
                    referenceTarget("目标黄感 b*", key: \.targetYellow, range: -30...60)
                    referenceTarget("亮度最大变化", key: \.maxLightnessChange, range: 0...14)
                    referenceTarget("色彩最大变化", key: \.maxColorChange, range: 0...10)
                    Toggle("保留原片明暗层次", isOn: Binding(get: { studio.selectedSkinTemplate?.preserveContrast ?? true },
                        set: { value in studio.updateSkinTemplate { $0.preserveContrast = value } }))
                    Toggle("保护自然脸颊红润", isOn: Binding(get: { studio.selectedSkinTemplate?.protectCheeks ?? true },
                        set: { value in studio.updateSkinTemplate { $0.protectCheeks = value } }))
                    Text("参考权重 \(Int(template.reference.reliability * 100))% · \(template.lips == nil ? "肤色目标" : "含相对唇色目标")")
                        .foregroundStyle(.secondary)
                    ForEach(template.reference.warnings, id: \.self) { warning in Text(warning).foregroundStyle(.secondary) }
                    HStack {
                        Text("应用强度")
                        Slider(value: $studio.referenceStrength, in: 0...1).accessibilityLabel("参考应用强度")
                    }
                    HStack {
                        Button("应用当前") { studio.applySkinTemplate(all: false) }
                        Button("逐张应用全部") { studio.applySkinTemplate(all: true) }
                            .disabled(studio.project.photos.count < 2)
                    }
                    Button("导出模板 JSON", action: studio.exportSkinTemplate)
                    Text("目标会随每张照片重新计算。编辑模板后，请重新应用以更新照片。")
                        .foregroundStyle(.secondary)
                }
                if let reference = studio.photo?.settings.skinReference {
                    Divider()
                    Text("已应用：" + reference.template.name).fontWeight(.medium)
                    appliedReferenceSlider("追色强度", key: \.strength)
                    appliedReferenceSlider("借鉴亮度", key: \.lightnessAmount)
                    appliedReferenceSlider("借鉴色彩", key: \.colorAmount)
                    VStack(spacing: 4) {
                        HStack {
                            Text("灰感补偿"); Spacer()
                            Text(String(format: "%.0f%%", (studio.photo?.settings.skinReference?.chromaCompensation ?? 0) * 100)).monospacedDigit()
                        }
                        Slider(value: Binding(get: { studio.photo?.settings.skinReference?.chromaCompensation ?? 0 },
                            set: { value in studio.updateSkinReference { $0.chromaCompensation = value } }), in: 0...1)
                            .accessibilityLabel("灰感补偿")
                        Text("大幅提亮后补回肤色浓度，避免脸部发灰。旧项目默认关闭。")
                            .foregroundStyle(.secondary)
                    }
                    Toggle("包含识别到的脖子", isOn: Binding(get: { studio.photo?.settings.skinReference?.includeNeck ?? true },
                        set: { value in studio.updateSkinReference { $0.includeNeck = value } }))
                    Picker("作用人物", selection: Binding(get: { studio.photo?.settings.skinReference?.faceIndex },
                        set: { value in studio.updateSkinReference { $0.faceIndex = value } })) {
                        Text("全部人物独立适配").tag(nil as Int?)
                        ForEach(studio.detectedFaces) { face in Text("人物 \(face.index + 1)").tag(Optional(face.index)) }
                    }
                    Toggle("协调身体肤色", isOn: Binding(get: { (studio.photo?.settings.skinReference?.bodyHarmonization ?? 0) > 0 },
                        set: { value in studio.updateSkinReference { $0.bodyHarmonization = value ? 0.8 : nil } }))
                    if (reference.bodyHarmonization ?? 0) > 0 {
                        Text("身体协调强度")
                        Slider(value: Binding(get: { studio.photo?.settings.skinReference?.bodyHarmonization ?? 0.8 },
                            set: { value in studio.updateSkinReference { $0.bodyHarmonization = value } }), in: 0...1)
                            .accessibilityLabel("身体协调强度")
                        Button("查看／修正身体候选") { studio.editReferenceMask(body: true) }
                        Text("按身体皮肤区域分别协调，保留自然明暗差。多人照片需手动处理身体。")
                            .foregroundStyle(.secondary)
                    }
                    Button("画笔修正参考作用区域") { studio.editReferenceMask() }
                    if studio.referenceMaskEditing {
                        Picker(studio.referenceBodyMaskEditing ? "身体蒙版画笔" : "参考蒙版画笔", selection: $studio.brushTool) {
                            ForEach(MaskBrushTool.allCases) { tool in Text(tool.label).tag(tool) }
                        }.pickerStyle(.segmented)
                        Slider(value: $studio.brushRadius, in: 0.001...0.05).accessibilityLabel("参考蒙版画笔大小")
                        Text("补选或擦除后可关闭蒙版查看效果，Option 临时擦除。")
                        if !(studio.referenceBodyMaskEditing ? reference.bodyBrushStrokes ?? [] : reference.brushStrokes ?? []).isEmpty {
                            Button("清除参考蒙版修正", action: studio.clearBrushStrokes)
                        }
                    }
                    HStack {
                        Button("检查应用效果", action: studio.checkSkinReference).disabled(studio.referenceBusy)
                        Button("移除", action: studio.removeSkinReference)
                    }
                    if !studio.referenceReportText.isEmpty { Text(studio.referenceReportText).foregroundStyle(.secondary) }
                }
            }
            .font(.system(size: 11))
            .padding(.top, 10)
        }
        .font(.system(size: 12, weight: .medium))
    }

    private func referenceTarget(_ title: String, key: WritableKeyPath<SkinStyleTemplate, Double>,
                                 range: ClosedRange<Double>) -> some View {
        let value = studio.selectedSkinTemplate?[keyPath: key] ?? range.lowerBound
        return VStack(spacing: 4) {
            HStack { Text(title); Spacer(); Text(String(format: "%.1f", value)).monospacedDigit() }
            Slider(value: Binding(get: { studio.selectedSkinTemplate?[keyPath: key] ?? range.lowerBound },
                set: { value in studio.updateSkinTemplate { $0[keyPath: key] = value } }), in: range)
                .accessibilityLabel(title)
        }
    }

    private func appliedReferenceSlider(_ title: String, key: WritableKeyPath<SkinReferenceApplication, Double>) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title); Spacer()
                Text(String(format: "%.0f%%", (studio.photo?.settings.skinReference?[keyPath: key] ?? 0) * 100)).monospacedDigit()
            }
            Slider(value: Binding(get: { studio.photo?.settings.skinReference?[keyPath: key] ?? 0 },
                set: { value in studio.updateSkinReference { $0[keyPath: key] = value } }), in: 0...1)
                .accessibilityLabel(title)
        }
    }
}
