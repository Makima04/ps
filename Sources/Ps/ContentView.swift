import AppKit
import ColorEngine
import SwiftUI

struct ContentView: View {
    @ObservedObject var studio: Studio
    @State private var showOriginal = false
    @State private var zoom = 0.0
    @State private var actualZoom = 1.0
    @State private var showingPresetName = false
    @State private var presetName = ""
    @State private var advanced = false
    @State private var showingBlemishReview = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                if advanced {
                    PresetsAndLayersSidebar(studio: studio, showingPresetName: $showingPresetName, presetName: $presetName)
                        .frame(width: 236)
                    Divider()
                }
                workspace
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                if advanced {
                    AdvancedInspectorView(studio: studio, showOriginal: $showOriginal, showingBlemishReview: $showingBlemishReview)
                        .frame(width: 280)
                } else {
                    QuickInspectorView(studio: studio, showOriginal: $showOriginal, showingBlemishReview: $showingBlemishReview)
                        .frame(width: 330)
                }
            }
            Divider()
            filmstrip
            Divider()
            footer
        }
        .background(studioBackground)
        .tint(studioAccent)
        .onChange(of: advanced) { _, _ in
            studio.activeLayerID = nil; studio.showMask = false; studio.repairMode = false
            studio.referenceMaskEditing = false; studio.brushTool = .inspect
        }
        .onChange(of: studio.selection) { _, _ in
            if !advanced { zoom = 0; showOriginal = false; showingBlemishReview = false }
        }
        .onChange(of: studio.selectedSkinTemplateID) { _, _ in
            if !advanced { studio.updatePortrait { _ in } }
        }
        .onChange(of: showOriginal) { _, enabled in if enabled { studio.repairMode = false } }
        .onChange(of: studio.showMask) { _, enabled in if enabled { studio.repairMode = false } }
        .dropDestination(for: URL.self) { urls, _ in
            studio.importFiles(urls)
            return true
        }
        .alert("预设名称", isPresented: $showingPresetName) {
            TextField("名称", text: $presetName)
            Button("保存") { studio.savePreset(named: presetName) }
            Button("取消", role: .cancel) {}
        }
        .alert("调色工作室", isPresented: Binding(
            get: { studio.alert != nil },
            set: { if !$0 { studio.alert = nil } }
        )) {
            Button("好") { studio.alert = nil }
        } message: {
            Text(studio.alert ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(studioAccent)
            Text("调色工作室")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            Picker("编辑模式", selection: $advanced) {
                Text("快速修图").tag(false)
                Text("高级编辑").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 180).disabled(studio.portraitBusy)
            Button(action: studio.undo) {
                Image(systemName: "arrow.uturn.backward")
            }
            .help("撤销")
            .disabled(!studio.history.canUndo)
            Button(action: studio.redo) {
                Image(systemName: "arrow.uturn.forward")
            }
            .help("重做")
            .disabled(!studio.history.canRedo)
            Button(action: studio.pickFiles) {
                Label("导入照片", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            Button { studio.export(all: false) } label: {
                Label("导出当前", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(studioBackground)
            .disabled(studio.photo == nil || studio.exporting || studio.portraitBusy)
        }
        .padding(.horizontal, 22)
        .frame(height: 66)
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            if let photo = studio.photo {
                HStack {
                    Text(photo.url.lastPathComponent)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer()
                    Picker("效果对比", selection: $showOriginal) {
                        Text("原图").tag(true); Text("修图效果").tag(false)
                    }.pickerStyle(.segmented).frame(width: 150)
                    if advanced {
                        Toggle("蒙版", isOn: $studio.showMask)
                            .toggleStyle(.button)
                            .disabled((studio.activeLayer == nil && !studio.referenceMaskEditing) || showOriginal)
                            .help("白色生效，黑色屏蔽，灰色部分生效")
                    }
                    Button("适应") { zoom = 0 }
                    Button("−") { zoom = max(0.02, actualZoom * 0.8) }
                    Text("\(Int((actualZoom * 100).rounded()))%")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 42)
                    Button("+") { zoom = min(8, actualZoom * 1.25) }
                    Button("100%") { zoom = 1 }
                }
                .controlSize(.small)
                .padding(14)
                PreviewView(photo: photo, engine: studio.previewEngine,
                            showOriginal: showOriginal, zoom: $zoom, actualZoom: $actualZoom,
                            maskLayerID: studio.showMask && !showOriginal ? studio.activeLayerID : nil,
                            brush: (studio.activeLayer == nil && !studio.referenceMaskEditing) || showOriginal ? .inspect : studio.brushTool,
                            brushRadius: studio.repairMode ? studio.repairRadius : studio.brushRadius, onStroke: studio.recordStroke,
                            repairMode: studio.repairMode && !showOriginal && !studio.showMask,
                            repairSource: studio.repairSource, onRepairPoint: studio.pickRepairPoint,
                            referenceMask: studio.referenceMaskEditing && studio.showMask && !showOriginal,
                            referenceBodyMask: studio.referenceBodyMaskEditing,
                            blemishes: studio.showBlemishCandidates && !showOriginal && !studio.showMask ? studio.blemishCandidates : [],
                            selectedBlemishes: studio.selectedBlemishIDs, focusedBlemishID: studio.focusedBlemishID)
                    .padding(12)
                Text(showOriginal ? "原图" : studio.showMask && studio.referenceMaskEditing ? "参考肤色作用区域 · 可用画笔修正" : studio.showMask && studio.activeLayer != nil ? "有效蒙版 · 含羽化、不透明度与高光保护" : "调色效果")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 14)
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 46, weight: .ultraLight))
                        .foregroundStyle(studioAccent)
                    VStack(spacing: 8) {
                        Text("从一张照片开始")
                            .font(.system(size: 24, weight: .medium))
                        Text("拖入 JPEG、TIFF 或照片文件夹")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    Button("导入照片", action: studio.pickFiles)
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(studioBackground)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var filmstrip: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 10) {
                ForEach(studio.project.photos) { photo in
                    Button { studio.selection = photo.id } label: {
                        PhotoThumbnail(photo: photo, selected: studio.selection == photo.id)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("从项目移除", role: .destructive) {
                            studio.selection = photo.id
                            studio.removeSelected()
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 116)
        .background(studioPanel.opacity(0.6))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(studio.project.photos.count) 张照片")
            if let photo = studio.photo {
                PhotoMetadata(url: photo.url)
            }
            Spacer()
            if studio.exporting {
                ProgressView().controlSize(.mini)
            }
            Text(studio.status).lineLimit(1)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .frame(height: 32)
    }
}
