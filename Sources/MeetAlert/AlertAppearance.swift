import AppKit
import SwiftUI

/// Popup-only preferences. Defaults preserve the original appearance and actions.
struct AlertAppearance: Codable, Equatable {
    var width = 640
    var height = 168
    var textScale = 100
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

    init() {}

    private enum CodingKeys: String, CodingKey {
        case width, height, textScale, showJoin, showSnooze, showDismiss, showIgnore
        case customColors, background, upcoming, imminent, started
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
        let defaults = Self()
        for key in [\Self.background, \.upcoming, \.imminent, \.started] {
            result[keyPath: key] = NSColor(hex: self[keyPath: key])?.hexString ?? defaults[keyPath: key]
        }
        return result
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
