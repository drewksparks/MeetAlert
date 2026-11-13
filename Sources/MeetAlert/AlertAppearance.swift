import AppKit
import SwiftUI

/// Popup-only preferences. Defaults preserve the original appearance and actions.
struct AlertAppearance: Codable, Equatable {
    var width = 640
    var height = 168
    var textScale = 100
    var translucency = 55
    var minimal = false
    var offsetX = 0
    var offsetY = 12
    var topEdge = false
    var slideFromTop = false
    var showJoin = true
    var showSnooze = true
    var showDismiss = true
    var showIgnore = true
    var customColors = false
    var background = "#FFFFFF"
    var upcoming = "#006A85"
    var imminent = "#9A5B00"
    var started = "#C41E17"

    static let widthRange = 480...1200
    static let heightRange = 168...480
    static let textScaleRange = 100...200
    static let translucencyRange = 0...100
    static let offsetXRange = -3000...3000
    static let offsetYRange = 0...1600

    init() {}

    private enum CodingKeys: String, CodingKey {
        case width, height, textScale, showJoin, showSnooze, showDismiss, showIgnore
        case customColors, background, upcoming, imminent, started
        case translucency, minimal, offsetX, offsetY, topEdge, slideFromTop
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A malformed appearance field must not discard unrelated preferences or older configs.
        width = (try? c.decode(Int.self, forKey: .width)) ?? width
        height = (try? c.decode(Int.self, forKey: .height)) ?? height
        textScale = (try? c.decode(Int.self, forKey: .textScale)) ?? textScale
        showJoin = (try? c.decode(Bool.self, forKey: .showJoin)) ?? showJoin
        showSnooze = (try? c.decode(Bool.self, forKey: .showSnooze)) ?? showSnooze
        showDismiss = (try? c.decode(Bool.self, forKey: .showDismiss)) ?? showDismiss
        showIgnore = (try? c.decode(Bool.self, forKey: .showIgnore)) ?? showIgnore
        customColors = (try? c.decode(Bool.self, forKey: .customColors)) ?? customColors
        // Earlier custom-color configs were opaque; retain that when migrating.
        translucency = (try? c.decode(Int.self, forKey: .translucency)) ?? (customColors ? 0 : translucency)
        minimal = (try? c.decode(Bool.self, forKey: .minimal)) ?? minimal
        offsetX = (try? c.decode(Int.self, forKey: .offsetX)) ?? offsetX
        offsetY = (try? c.decode(Int.self, forKey: .offsetY)) ?? offsetY
        topEdge = (try? c.decode(Bool.self, forKey: .topEdge)) ?? topEdge
        slideFromTop = (try? c.decode(Bool.self, forKey: .slideFromTop)) ?? slideFromTop
        background = (try? c.decode(String.self, forKey: .background)) ?? background
        upcoming = (try? c.decode(String.self, forKey: .upcoming)) ?? upcoming
        imminent = (try? c.decode(String.self, forKey: .imminent)) ?? imminent
        started = (try? c.decode(String.self, forKey: .started)) ?? started
        self = normalized
    }

    var normalized: Self {
        var result = self
        result.width = min(max(width, Self.widthRange.lowerBound), Self.widthRange.upperBound)
        result.height = min(max(height, Self.heightRange.lowerBound), Self.heightRange.upperBound)
        result.textScale = min(max(textScale, Self.textScaleRange.lowerBound), Self.textScaleRange.upperBound)
        result.translucency = min(max(translucency, 0), 100)
        result.offsetX = min(max(offsetX, Self.offsetXRange.lowerBound), Self.offsetXRange.upperBound)
        result.offsetY = min(max(offsetY, Self.offsetYRange.lowerBound), Self.offsetYRange.upperBound)
        let defaults = Self()
        for key in [\Self.background, \.upcoming, \.imminent, \.started] {
            result[keyPath: key] = NSColor(hex: self[keyPath: key])?.hexString ?? defaults[keyPath: key]
        }
        return result
    }

    enum Preset: String, CaseIterable {
        case original = "Original", solid = "Solid", minimal = "Minimal"
    }

    mutating func apply(_ preset: Preset) {
        // Presets change presentation only; preserve the user's position and saved color choices.
        width = preset == .minimal ? 480 : 640
        height = 168
        textScale = 100
        minimal = preset == .minimal
        translucency = preset == .solid ? 0 : preset == .minimal ? 70 : 55
        customColors = false
        showJoin = true
        showDismiss = true
        showSnooze = preset != .minimal
        showIgnore = preset != .minimal
    }

    var scale: CGFloat { CGFloat(normalized.textScale) / 100 }
}

extension NSColor {
    private var relativeLuminance: CGFloat {
        let rgb = usingColorSpace(.sRGB) ?? .black
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }

    func contrastRatio(against other: NSColor) -> CGFloat {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    var contrastingText: NSColor {
        contrastRatio(against: .black) >= contrastRatio(against: .white) ? .black : .white
    }

    /// Keep the chosen hue where possible; adjust brightness for readable small text and icons.
    func readable(on background: NSColor) -> NSColor {
        guard contrastRatio(against: background) < 4.5 else { return self }
        let target = background.contrastingText
        let rgb = usingColorSpace(.sRGB) ?? target
        let end = target.usingColorSpace(.sRGB) ?? target
        for step in 1...100 {
            let amount = CGFloat(step) / 100
            let adjusted = NSColor(srgbRed: rgb.redComponent + (end.redComponent - rgb.redComponent) * amount,
                                   green: rgb.greenComponent + (end.greenComponent - rgb.greenComponent) * amount,
                                   blue: rgb.blueComponent + (end.blueComponent - rgb.blueComponent) * amount,
                                   alpha: 1)
            if adjusted.contrastRatio(against: background) >= 4.5 { return adjusted }
        }
        return target
    }
}

/// Wrap actions and metadata without shrinking text or losing keyboard-accessible controls.
struct AlertFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = arrangement(width: bounds.width, subviews: subviews).positions
        for (index, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX + positions[index].x, y: bounds.minY + positions[index].y),
                       proposal: ProposedViewSize(view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))))
        }
    }

    private func arrangement(width: CGFloat?, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let limit = width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        var positions: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > limit { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            positions.append(CGPoint(x: x, y: y))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width ?? usedWidth, height: y + rowHeight), positions)
    }
}

/// Coordinate math is independent of NSScreen so secondary displays and edge clamping are testable.
enum AlertPlacement {
    static func frame(size: CGSize, screen: CGRect, visible: CGRect,
                      appearance: AlertAppearance, precedingHeight: CGFloat = 0) -> CGRect {
        let options = appearance.normalized
        let area = options.topEdge ? screen : visible
        let width = min(size.width, max(1, area.width - 24))
        let x = min(max(area.midX - width / 2 + CGFloat(options.offsetX), area.minX + 12), area.maxX - width - 12)
        let y = max(area.minY, area.maxY - CGFloat(options.offsetY) - precedingHeight - size.height)
        return CGRect(x: x, y: y, width: width, height: size.height)
    }

    static func entranceFrame(final: CGRect, screen: CGRect, slideFromTop: Bool, reduceMotion: Bool) -> CGRect {
        guard !reduceMotion else { return final }
        return slideFromTop ? CGRect(x: final.minX, y: screen.maxY, width: final.width, height: final.height)
            : final.offsetBy(dx: 0, dy: 14)
    }
}
