import AppKit
import ColorEngine
import SwiftUI

enum MaskBrushTool: String, CaseIterable, Identifiable {
    case inspect, add, erase
    var id: Self { self }
    var label: String {
        switch self {
        case .inspect: "查看"
        case .add: "补选"
        case .erase: "擦除"
        }
    }
}

struct PhotoCanvas: NSViewRepresentable {
    let image: CGImage
    let displayScale: CGFloat
    @Binding var zoom: Double
    @Binding var actualZoom: Double
    let brush: MaskBrushTool
    let radius: Double
    let onStroke: (MaskStroke) -> Void
    var repairMode = false
    var repairSource: MaskPoint?
    var onRepairPoint: ((MaskPoint, Bool) -> Void)?
    var blemishes: [BlemishCandidate] = []
    var selectedBlemishes: Set<UUID> = []
    var focusedBlemishID: UUID?

    func makeNSView(context: Context) -> CanvasScrollView {
        let scroll = CanvasScrollView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.02
        scroll.maxMagnification = 8
        scroll.drawsBackground = false
        scroll.contentView = CenteredClipView()
        scroll.contentView.drawsBackground = false
        scroll.documentView = CanvasImageView()
        return scroll
    }

    func updateNSView(_ scroll: CanvasScrollView, context: Context) {
        guard let canvas = scroll.documentView as? CanvasImageView else { return }
        canvas.image = image
        canvas.brush = brush
        canvas.radius = radius
        canvas.onStroke = onStroke
        canvas.repairMode = repairMode
        canvas.repairSource = repairSource
        canvas.onRepairPoint = onRepairPoint
        canvas.blemishes = blemishes
        canvas.selectedBlemishes = selectedBlemishes
        canvas.focusedBlemishID = focusedBlemishID
        let size = CGSize(width: CGFloat(image.width) / displayScale,
                          height: CGFloat(image.height) / displayScale)
        if canvas.frame.size != size { canvas.setFrameSize(size) }
        scroll.desiredZoom = zoom
        scroll.onZoom = { value, userGesture in
            DispatchQueue.main.async {
                if abs(actualZoom - value) > 0.0001 { actualZoom = value }
                if userGesture && abs(zoom - value) > 0.0001 { zoom = value }
            }
        }
        scroll.updateZoom()
        if let id = focusedBlemishID, id != scroll.lastBlemishFocusID,
           let spot = blemishes.first(where: { $0.id == id }) {
            scroll.lastBlemishFocusID = id
            let value = max(1, scroll.magnification)
            scroll.desiredZoom = value
            scroll.setMagnification(value, centeredAt: CGPoint(x: spot.target.x*size.width, y: spot.target.y*size.height))
            scroll.onZoom?(value, true)
        }
        if focusedBlemishID == nil { scroll.lastBlemishFocusID = nil }
        canvas.needsDisplay = true
        canvas.window?.invalidateCursorRects(for: canvas)
    }
}

final class CenteredClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return bounds }
        if bounds.width > documentView.frame.width {
            bounds.origin.x = (documentView.frame.width - bounds.width) / 2
        }
        if bounds.height > documentView.frame.height {
            bounds.origin.y = (documentView.frame.height - bounds.height) / 2
        }
        return bounds
    }
}

final class CanvasScrollView: NSScrollView {
    var lastBlemishFocusID: UUID?
    var desiredZoom = 0.0
    var onZoom: ((Double, Bool) -> Void)?
    private var updating = false

    override func layout() {
        super.layout()
        updateZoom()
    }

    func updateZoom() {
        guard !updating, let documentView, documentView.frame.width > 0,
              contentView.frame.width > 0, contentView.frame.height > 0 else { return }
        updating = true
        defer { updating = false }
        let fit = min(contentView.frame.width / documentView.frame.width,
                      contentView.frame.height / documentView.frame.height)
        let value = min(maxMagnification, max(minMagnification, desiredZoom == 0 ? fit : desiredZoom))
        if abs(magnification - value) > 0.0001 {
            let center = CGPoint(x: documentVisibleRect.midX, y: documentVisibleRect.midY)
            setMagnification(value, centeredAt: center)
        }
        onZoom?(magnification, false)
    }

    override func magnify(with event: NSEvent) {
        updating = true
        super.magnify(with: event)
        desiredZoom = magnification
        updating = false
        onZoom?(magnification, true)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        let location = documentView?.convert(event.locationInWindow, from: nil) ?? .zero
        let value = min(maxMagnification, max(minMagnification, magnification * exp(-event.scrollingDeltaY * 0.015)))
        desiredZoom = value
        updating = true
        setMagnification(value, centeredAt: location)
        updating = false
        desiredZoom = magnification
        onZoom?(magnification, true)
    }
}

final class CanvasImageView: NSView {
    var image: CGImage?
    var brush: MaskBrushTool = .inspect
    var radius = 0.008
    var onStroke: ((MaskStroke) -> Void)?
    var repairMode = false
    var repairSource: MaskPoint?
    var onRepairPoint: ((MaskPoint, Bool) -> Void)?
    var blemishes: [BlemishCandidate] = []
    var selectedBlemishes: Set<UUID> = []
    var focusedBlemishID: UUID?
    private var stroke: MaskStroke?
    private var dragStart = CGPoint.zero
    private var scrollStart = CGPoint.zero

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: brush == .inspect && !repairMode ? .openHand : .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = (enclosingScrollView?.magnification ?? 1) >= 1 ? .none : .high
        context.draw(image, in: bounds)
        let magnification = max(0.02, enclosingScrollView?.magnification ?? 1)
        for (index, spot) in blemishes.enumerated() {
            let color: NSColor = spot.id == focusedBlemishID ? .systemCyan : selectedBlemishes.contains(spot.id) ? .systemGreen : .systemOrange
            color.setStroke()
            let r = max(spot.radius * max(bounds.width,bounds.height), 5/magnification)
            let p = CGPoint(x:spot.target.x*bounds.width,y:spot.target.y*bounds.height)
            let path = NSBezierPath(ovalIn:CGRect(x:p.x-r,y:p.y-r,width:2*r,height:2*r))
            path.lineWidth = 1.5/magnification; path.stroke()
            ("\(index+1)" as NSString).draw(at:CGPoint(x:p.x+r+2/magnification,y:p.y+r), withAttributes:[
                .font:NSFont.boldSystemFont(ofSize:11/magnification), .foregroundColor:color,
                .backgroundColor:NSColor.black.withAlphaComponent(0.65)])
        }
        if repairMode, let source = repairSource {
            NSColor.systemYellow.setStroke()
            let r = radius * max(bounds.width, bounds.height)
            let point = CGPoint(x: source.x * bounds.width, y: source.y * bounds.height)
            let path = NSBezierPath(ovalIn: CGRect(x: point.x - r, y: point.y - r, width: 2*r, height: 2*r))
            path.lineWidth = 1 / max(0.02, enclosingScrollView?.magnification ?? 1)
            path.stroke()
        }
        guard let stroke, let first = stroke.points.first else { return }
        let diameter = stroke.radius * max(bounds.width, bounds.height) * 2
        let color = stroke.erase ? NSColor.systemRed : NSColor.systemGreen
        color.withAlphaComponent(0.55).setStroke()
        color.withAlphaComponent(0.55).setFill()
        let start = CGPoint(x: first.x * bounds.width, y: first.y * bounds.height)
        if stroke.points.count == 1 {
            NSBezierPath(ovalIn: CGRect(x: start.x - diameter / 2, y: start.y - diameter / 2,
                                       width: diameter, height: diameter)).fill()
        } else {
            let path = NSBezierPath()
            path.lineWidth = diameter
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: start)
            for point in stroke.points.dropFirst() {
                path.line(to: CGPoint(x: point.x * bounds.width, y: point.y * bounds.height))
            }
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if repairMode {
            onRepairPoint?(normalized(event), event.modifierFlags.contains(.option))
            return
        }
        if brush == .inspect {
            dragStart = event.locationInWindow
            scrollStart = enclosingScrollView?.contentView.bounds.origin ?? .zero
            NSCursor.closedHand.set()
        } else {
            stroke = MaskStroke(points: [normalized(event)], radius: radius,
                                erase: brush == .erase || event.modifierFlags.contains(.option))
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !repairMode else { return }
        if brush == .inspect, let scroll = enclosingScrollView {
            let position = event.locationInWindow
            let point = CGPoint(x: scrollStart.x - (position.x - dragStart.x) / scroll.magnification,
                                y: scrollStart.y - (position.y - dragStart.y) / scroll.magnification)
            scroll.contentView.scroll(to: point)
            scroll.reflectScrolledClipView(scroll.contentView)
        } else {
            stroke?.points.append(normalized(event))
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let stroke {
            onStroke?(stroke)
            self.stroke = nil
            needsDisplay = true
        }
        if brush == .inspect { NSCursor.openHand.set() }
    }

    private func normalized(_ event: NSEvent) -> MaskPoint {
        let location = convert(event.locationInWindow, from: nil)
        return MaskPoint(x: min(1, max(0, location.x / bounds.width)),
                         y: min(1, max(0, location.y / bounds.height)))
    }
}
