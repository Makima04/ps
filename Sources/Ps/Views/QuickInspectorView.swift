import ColorEngine
import SwiftUI

struct QuickInspectorView: View {
    @ObservedObject var studio: Studio
    @Binding var showOriginal: Bool
    @Binding var showingBlemishReview: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("人像修图").font(.system(size: 20, weight: .semibold))
                    Text("选风格，自动处理，再按喜好微调。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("肤色风格").font(.system(size: 12, weight: .medium))
                    Picker("肤色风格", selection: quickBinding(\.look)) {
                        ForEach(PortraitLook.allCases) { look in Text(look.label).tag(look) }
                    }.pickerStyle(.segmented).labelsHidden()
                    Button { studio.runPortrait(all: false); showOriginal = false } label: {
                        Label(studio.photo?.settings.portraitIntent == nil ? "一键自动修图" : "重新自动修图", systemImage: "wand.and.stars")
                            .font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 9)
                    }.buttonStyle(.borderedProminent).foregroundStyle(studioBackground)
                        .help("重新生成调色，保留本张修复点。可撤销回到处理前。")
                    if studio.project.photos.count > 1 {
                        Button("按此风格处理全部 \(studio.project.photos.count) 张") { studio.runPortrait(all: true); showOriginal = false }
                            .buttonStyle(.bordered).frame(maxWidth: .infinity)
                    }
                }.disabled(studio.photo == nil || studio.portraitBusy || studio.exporting)
                if studio.portraitBusy {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(studio.portraitProgress).font(.system(size: 12))
                        Button("取消处理", action: studio.cancelPortrait)
                    }
                } else if let summary = studio.photo?.portraitSummary {
                    Label(summary, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("自动补光、协调肤色与唇色，并分析小瑕疵。处理后可直接微调。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if let warnings = studio.photo?.portraitWarnings, !warnings.isEmpty {
                    Label(warnings.joined(separator: "\n"), systemImage: "exclamationmark.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                VStack(alignment: .leading, spacing: 18) {
                    Text("微调观感").font(.headline)
                    quickSlider("提亮程度", key: \.brightness)
                    quickSlider("肤色均匀", key: \.uniformity)
                    quickSlider("皮肤柔化", key: \.softness)
                    Picker("唇色", selection: quickBinding(\.lip)) {
                        ForEach(PortraitLip.allCases) { lip in Text(lip.label).tag(lip) }
                    }
                    quickSlider("唇色强度", key: \.lipStrength)
                    Toggle("协调脸与身体肤色", isOn: quickBinding(\.harmonizeBody)).font(.system(size: 12))
                    Toggle("处理时修复明显红点", isOn: Binding(get: { studio.portraitOptions.repairRedSpots }, set: { studio.portraitOptions.repairRedSpots = $0 }))
                        .font(.system(size: 12)).help("下次自动处理时生效；深色点仅提示，不自动修复。")
                    Text("已有编辑时，点击自动修图会重新生成调色；原照片始终保留。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.disabled(studio.photo == nil || studio.portraitBusy)
                DisclosureGroup("借鉴参考图（可选）") {
                    VStack(alignment: .leading, spacing: 10) {
                        Button("导入参考图", action: studio.pickSkinReference).disabled(studio.referenceBusy)
                        if studio.referenceBusy { ProgressView().controlSize(.small) }
                        if !studio.skinTemplates.isEmpty {
                            Picker("参考", selection: $studio.selectedSkinTemplateID) {
                                Text("选择参考").tag(nil as UUID?)
                                ForEach(studio.skinTemplates) { template in Text(template.name).tag(Optional(template.id)) }
                            }.labelsHidden()
                            Toggle("借鉴参考肤色", isOn: quickBinding(\.useReference))
                        }
                        Text("也可以只在唇色中选择“借鉴参考”。")
                            .foregroundStyle(.secondary)
                    }.font(.system(size: 12)).padding(.top, 8)
                }.font(.system(size: 12)).disabled(studio.portraitBusy)
                Button("检查局部细节") {
                    showingBlemishReview = true
                    studio.reviewPortraitDetails()
                }.disabled(studio.photo == nil || studio.portraitBusy || studio.blemishBusy)
                if showingBlemishReview {
                    BlemishControls(studio: studio, isExpanded: $showingBlemishReview)
                }
                Divider()
                Button { studio.export(all: true) } label: {
                    Label("导出全部 \(studio.project.photos.count) 张", systemImage: "square.and.arrow.up.on.square")
                        .frame(maxWidth: .infinity)
                }.disabled(studio.photo == nil || studio.exporting || studio.portraitBusy)
                Text("需要蒙版、图层或局部光影时，切换到顶部“高级编辑”。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(22)
        }.background(studioPanel)
    }

    private func quickBinding<Value>(_ key: WritableKeyPath<PortraitIntent, Value>) -> Binding<Value> {
        Binding(get: { studio.portraitOptions[keyPath: key] },
                set: { value in studio.updatePortrait { $0[keyPath: key] = value } })
    }

    private func quickSlider(_ title: String, key: WritableKeyPath<PortraitIntent, Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(studio.portraitOptions[keyPath: key] * 100))").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: quickBinding(key), in: 0...1).accessibilityLabel(title)
        }.font(.system(size: 12))
    }
}
