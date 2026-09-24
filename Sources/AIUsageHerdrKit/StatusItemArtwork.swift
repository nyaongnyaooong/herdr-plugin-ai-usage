import AppKit
import CoreText
import AIUsageCore

enum StatusItemArtwork {
    private static let barHeight: CGFloat = 22
    private static let iconSize: CGFloat = 16
    private static let iconTextSpacing: CGFloat = 3
    private static let providerSpacing: CGFloat = 8
    private static let horizontalPadding: CGFloat = 4
    private static let labelPercentGap: CGFloat = 3
    private static let textToBar: CGFloat = 4
    private static let meterWidth: CGFloat = 24
    private static let meterThickness: CGFloat = 3.5

    static func image(
        snapshot: UsageSnapshot?,
        visibleIDs: [ProviderID],
        fontID: MenuBarFontID,
        appearance: NSAppearance
    ) -> NSImage {
        let style = MenuBarStyle(appearance: appearance)
        let fonts = Fonts(
            line: fontID.nsFont(size: 11),
            singleLine: fontID.nsFont(size: 13),
            api: fontID.nsFont(size: 12)
        )
        return appearance.withDrawingAppearance {
            rasterize(render(snapshot: snapshot, visibleIDs: visibleIDs, style: style, fonts: fonts))
        }
    }

    static func tooltip(snapshot: UsageSnapshot?, visibleIDs: [ProviderID]) -> String {
        let ids = visibleIDs.isEmpty ? ProviderID.allCases : visibleIDs
        return ids.map { id in
            let provider = snapshot?.provider(id)
            if provider?.left.remainingPercent == nil,
               provider?.right.remainingPercent == nil,
               let api = provider?.api {
                return "\(id.displayName) \(api.label) \(api.detail)"
            }
            let meters = MenuBarFormatting.compactVisible(
                leftLabel: id.menuBarLeftLabel,
                left: provider?.left.remainingPercent,
                rightLabel: id.menuBarRightLabel,
                right: provider?.right.remainingPercent
            )
            return "\(id.displayName) \(meters)"
        }.joined(separator: "\n")
    }

    private struct MenuBarStyle {
        let isDark: Bool
        let foreground: NSColor
        let warning: NSColor
        let critical: NSColor
        let halo: NSColor

        init(appearance: NSAppearance) {
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            self.isDark = isDark
            foreground = isDark ? .white : .black
            warning = Self.snapshot(.systemOrange, appearance: appearance)
            critical = Self.snapshot(.systemRed, appearance: appearance)
            halo = (isDark ? NSColor.black : NSColor.white).withAlphaComponent(isDark ? 0.7 : 0.92)
        }

        private static func snapshot(_ color: NSColor, appearance: NSAppearance) -> NSColor {
            var resolved = color
            appearance.performAsCurrentDrawingAppearance {
                resolved = color.usingColorSpace(.deviceRGB) ?? color
            }
            return resolved
        }

        func color(for level: MeterColorLevel) -> NSColor {
            switch level {
            case .critical: return critical
            case .warning: return warning
            case .normal: return foreground
            }
        }
    }

    private struct Fonts {
        let line: NSFont
        let singleLine: NSFont
        let api: NSFont
    }

    private struct UsageLine {
        let label: NSAttributedString
        let percent: NSAttributedString
        let remaining: Int?
    }

    private static func render(
        snapshot: UsageSnapshot?,
        visibleIDs: [ProviderID],
        style: MenuBarStyle,
        fonts: Fonts
    ) -> NSImage {
        let parts: [DrawnPart]
        if visibleIDs.isEmpty {
            parts = [.text(labelString("AI", font: fonts.api, style: style))]
        } else {
            parts = visibleIDs.enumerated().flatMap { index, id -> [DrawnPart] in
                var items = providerParts(for: snapshot?.provider(id), id: id, style: style, fonts: fonts)
                if index < visibleIDs.count - 1 {
                    items.append(.gap(providerSpacing))
                }
                return items
            }
        }

        let width = ceil(horizontalPadding * 2 + parts.reduce(0) { $0 + $1.width })
        let size = NSSize(width: max(width, 18), height: barHeight)
        let shadow = NSShadow()
        shadow.shadowColor = style.halo
        shadow.shadowBlurRadius = 1.6
        shadow.shadowOffset = .zero

        return NSImage(size: size, flipped: false) { rect in
            shadow.set()
            var x = horizontalPadding
            for part in parts {
                switch part {
                case .icon(let id):
                    let iconRect = NSRect(
                        x: x,
                        y: (rect.height - iconSize) / 2,
                        width: iconSize,
                        height: iconSize
                    )
                    let tinted = tintedIcon(ProviderIcon.image(for: id), color: style.foreground)
                    tinted.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
                    x += iconSize + iconTextSpacing
                case .text(let string):
                    let textSize = string.size()
                    let textRect = NSRect(
                        x: x,
                        y: (rect.height - textSize.height) / 2,
                        width: ceil(textSize.width),
                        height: ceil(textSize.height)
                    )
                    string.draw(in: textRect)
                    x += ceil(textSize.width)
                case .usageLines(let lines, let font):
                    drawUsageLines(lines, font: font, atX: x, in: rect, style: style)
                    x += usageStackWidth(lines)
                case .gap(let value):
                    x += value
                }
            }
            return true
        }
    }

    private static func providerParts(for provider: ProviderSnapshot?, id: ProviderID, style: MenuBarStyle, fonts: Fonts) -> [DrawnPart] {
        if provider?.left.remainingPercent == nil,
           provider?.right.remainingPercent == nil,
           let api = provider?.api {
            return [
                .icon(id),
                .text(labelString("API \(api.detail)", font: fonts.api, style: style))
            ]
        }
        let candidates: [(String, Int?)] = [
            (id.menuBarLeftLabel, provider?.left.remainingPercent),
            (id.menuBarRightLabel, provider?.right.remainingPercent)
        ]
        let filled = candidates.filter { $0.1 != nil }
        let shown = filled.isEmpty ? candidates : filled
        let font = shown.count == 1 ? fonts.singleLine : fonts.line
        return [
            .icon(id),
            .usageLines(shown.map { usageLine(label: $0.0, remaining: $0.1, style: style, font: font) }, font: font)
        ]
    }

    private static func usageLine(label: String, remaining: Int?, style: MenuBarStyle, font: NSFont) -> UsageLine {
        let color = style.color(for: MeterColor.level(remainingPercent: remaining))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .kern: 0.2
        ]
        return UsageLine(
            label: NSAttributedString(string: label, attributes: attributes),
            percent: NSAttributedString(string: MenuBarFormatting.percent(remaining), attributes: attributes),
            remaining: remaining
        )
    }

    private static func drawUsageLines(_ lines: [UsageLine], font: NSFont, atX x: CGFloat, in rect: NSRect, style: MenuBarStyle) {
        let labelWidth = columnWidth(lines.map(\.label))
        let percentWidth = columnWidth(lines.map(\.percent))
        let baselines = lineBaselines(count: lines.count, in: rect, font: font)
        for (line, baseline) in zip(lines.reversed(), baselines) {
            let originY = baseline + font.descender
            line.label.draw(at: NSPoint(x: x, y: originY))
            let percentSize = line.percent.size()
            line.percent.draw(at: NSPoint(
                x: x + labelWidth + labelPercentGap + (percentWidth - percentSize.width),
                y: originY
            ))
            let meterRect = NSRect(
                x: x + labelWidth + labelPercentGap + percentWidth + textToBar,
                y: baseline + (font.capHeight - meterThickness) / 2,
                width: meterWidth,
                height: meterThickness
            )
            drawMeter(in: meterRect, remaining: line.remaining, style: style)
        }
    }

    private static func lineBaselines(count: Int, in rect: NSRect, font: NSFont) -> [CGFloat] {
        let top = rect.maxY - 1.4 - font.capHeight
        let bottom = 1.1 - font.descender
        if count <= 1 {
            return [(rect.height - font.capHeight) / 2]
        }
        return [bottom, top]
    }

    private static func columnWidth(_ strings: [NSAttributedString]) -> CGFloat {
        ceil(strings.map { $0.size().width }.max() ?? 0)
    }

    private static func usageStackWidth(_ lines: [UsageLine]) -> CGFloat {
        columnWidth(lines.map(\.label)) + labelPercentGap + columnWidth(lines.map(\.percent)) + textToBar + meterWidth
    }

    private static func drawMeter(in rect: NSRect, remaining: Int?, style: MenuBarStyle) {
        let radius = rect.height / 2
        let track = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        style.foreground.withAlphaComponent(0.22).setFill()
        track.fill()
        guard let remaining else { return }
        let used = min(1, max(0, Double(100 - remaining) / 100.0))
        guard used > 0 else { return }
        var fillRect = rect
        fillRect.size.width = min(rect.width, max(rect.height, rect.width * CGFloat(used)))
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
        style.color(for: MeterColor.level(remainingPercent: remaining)).setFill()
        fill.fill()
    }

    private static func rasterize(_ image: NSImage) -> NSImage {
        let scale = max(NSScreen.screens.map(\.backingScaleFactor).max() ?? 2, 2)
        let pixelSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize.width.rounded(.up)),
            pixelsHigh: Int(pixelSize.height.rounded(.up)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            image.isTemplate = false
            return image
        }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(
            in: NSRect(origin: .zero, size: image.size),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        let baked = NSImage(size: image.size)
        baked.addRepresentation(rep)
        baked.isTemplate = false
        return baked
    }

    private static func labelString(_ value: String, font: NSFont, style: MenuBarStyle) -> NSAttributedString {
        NSAttributedString(string: value, attributes: [
            .font: font,
            .foregroundColor: style.foreground
        ])
    }

    private static func tintedIcon(_ source: NSImage, color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: iconSize, height: iconSize), flipped: false) { rect in
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [
                .interpolation: NSImageInterpolation.high
            ])
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    private enum DrawnPart {
        case icon(ProviderID)
        case text(NSAttributedString)
        case usageLines([UsageLine], font: NSFont)
        case gap(CGFloat)

        var width: CGFloat {
            switch self {
            case .icon: return iconSize + iconTextSpacing
            case .text(let string): return ceil(string.size().width)
            case .usageLines(let lines, _): return usageStackWidth(lines)
            case .gap(let value): return value
            }
        }
    }
}

private extension NSAppearance {
    func withDrawingAppearance<T>(_ body: () -> T) -> T {
        var result: T!
        performAsCurrentDrawingAppearance {
            result = body()
        }
        return result
    }
}
