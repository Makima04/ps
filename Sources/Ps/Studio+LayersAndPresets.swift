import ColorEngine
import Foundation

extension Studio {
    func setColor(_ color: ColorAdjustments) {
        guard var settings = photo?.settings else { return }
        if let index = settings.layers.firstIndex(where: { $0.id == activeLayerID }) {
            settings.layers[index].adjustments = color
        } else {
            settings.global = color
        }
        setAdjustments(settings)
    }

    func addLayer(mask: MaskKind) {
        guard var settings = photo?.settings else { return }
        var layer = AdjustmentLayer(mask: mask)
        if mask == .lips { layer.adjustments.lipStyle = .original }
        settings.layers.append(layer)
        setAdjustments(settings)
        activeLayerID = layer.id
        showMask = false
    }

    func addPortraitLayers() {
        guard var settings = photo?.settings else { return }
        let layers = Adjustments.portraitLayers()
        settings.layers.append(contentsOf: layers)
        setAdjustments(settings)
        activeLayerID = layers.first?.id
        showMask = false
    }

    func addSkinAndClothingLayers() {
        guard var settings = photo?.settings else { return }
        let skin = AdjustmentLayer(mask: .skin)
        let clothing = AdjustmentLayer(mask: .clothing)
        settings.layers.append(contentsOf: [skin, clothing])
        setAdjustments(settings)
        activeLayerID = skin.id
        showMask = true
        brushTool = .inspect
    }

    func recordStroke(_ stroke: MaskStroke) {
        if referenceMaskEditing {
            if referenceBodyMaskEditing { updateSkinReference { $0.bodyBrushStrokes = ($0.bodyBrushStrokes ?? []) + [stroke] } }
            else { updateSkinReference { $0.brushStrokes = ($0.brushStrokes ?? []) + [stroke] } }
            return
        }
        updateLayer {
            var strokes = $0.brushStrokes ?? []
            strokes.append(stroke)
            $0.brushStrokes = strokes
        }
    }

    func pickRepairPoint(_ point: MaskPoint, sample: Bool) {
        if sample || repairSource == nil {
            repairSource = point
            status = "已取样，点击小瑕疵进行修复；Option 点按可重新取样"
            return
        }
        guard let source = repairSource, let photo else { return }
        let spot = RepairSpot(source: source, target: point, radius: repairRadius)
        do {
            let info = try PhotoInfo.read(PhotoSource.resolve(photo.url).imageURL)
            guard spot.isValid(in: CGSize(width: info.width, height: info.height)) else {
                alert = "修复点或取样点太靠近边缘，请缩小笔刷或重新取样。"
                return
            }
            var settings = photo.settings
            settings.repairSpots = (settings.repairSpots ?? []) + [spot]
            setAdjustments(settings)
            status = "已修复一处 · 可撤销"
        } catch { alert = error.localizedDescription }
    }

    func clearRepairSpots() {
        guard var settings = photo?.settings else { return }
        settings.repairSpots = nil
        setAdjustments(settings)
    }

    func clearBrushStrokes() {
        if referenceMaskEditing {
            if referenceBodyMaskEditing { updateSkinReference { $0.bodyBrushStrokes = nil } }
            else { updateSkinReference { $0.brushStrokes = nil } }
            return
        }
        updateLayer { $0.brushStrokes = nil }
    }

    private func template(_ settings: Adjustments) -> Adjustments {
        var template = settings
        template.repairSpots = nil
        template.skinReference?.brushStrokes = nil
        template.skinReference?.bodyBrushStrokes = nil
        for index in template.layers.indices { template.layers[index].brushStrokes = nil }
        return template
    }

    func updateLayer(_ update: (inout AdjustmentLayer) -> Void) {
        guard var settings = photo?.settings,
              let index = settings.layers.firstIndex(where: { $0.id == activeLayerID }) else { return }
        update(&settings.layers[index])
        setAdjustments(settings)
    }

    func useSelectedLipTemplate() {
        guard let template = selectedSkinTemplate, template.lips != nil else {
            alert = "请先导入含唇色特征的参考图并选择模板"
            return
        }
        updateLayer {
            $0.lipReference = template
            $0.adjustments.lipStyle = .reference
        }
        status = "已独立应用唇色目标，每张照片按自身唇色计算"
    }

    func toggleLayer(_ id: UUID) {
        guard var settings = photo?.settings,
              let index = settings.layers.firstIndex(where: { $0.id == id }) else { return }
        settings.layers[index].enabled.toggle()
        setAdjustments(settings)
    }

    func removeLayer() {
        guard var settings = photo?.settings else { return }
        settings.layers.removeAll { $0.id == activeLayerID }
        setAdjustments(settings)
    }

    func moveLayer(up: Bool) {
        guard var settings = photo?.settings,
              let index = settings.layers.firstIndex(where: { $0.id == activeLayerID }) else { return }
        let destination = up ? index + 1 : index - 1
        guard settings.layers.indices.contains(destination) else { return }
        settings.layers.swapAt(index, destination)
        setAdjustments(settings)
    }

    func syncAll() {
        guard let settings = photo?.settings else { return }
        var updated = project
        updated.photos = updated.photos.map { photo in
            var copy = photo
            if copy.id == selection {
                copy.settings = settings
            } else {
                var synchronized = template(settings)
                synchronized.repairSpots = copy.settings.repairSpots
                if synchronized.skinReference?.template.id == copy.settings.skinReference?.template.id {
                    synchronized.skinReference?.brushStrokes = copy.settings.skinReference?.brushStrokes
                    synchronized.skinReference?.bodyBrushStrokes = copy.settings.skinReference?.bodyBrushStrokes
                }
                for index in synchronized.layers.indices {
                    let id = synchronized.layers[index].id
                    synchronized.layers[index].brushStrokes = copy.settings.layers.first { $0.id == id }?.brushStrokes
                }
                copy.settings = synchronized
            }
            return copy
        }
        commit(updated, name: "同步调色")
        status = "已同步到 \(project.photos.count) 张照片 · 区域逐张识别，画笔修正仅保留各自照片"
    }

    func savePreset(named input: String) {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let settings = photo?.settings, !name.isEmpty else { return }
        guard !Preset.standard.contains(where: { $0.name == name }) else {
            alert = "请选择与内置预设不同的名称。"
            return
        }
        let preset = Preset(name: name, settings: template(settings))
        var updated = project
        if let index = updated.customPresets.firstIndex(where: { $0.name == name }) {
            updated.customPresets[index] = preset
        } else {
            updated.customPresets.append(preset)
        }
        commit(updated, name: "保存预设")
        status = "已保存预设「\(name)」"
    }
}
