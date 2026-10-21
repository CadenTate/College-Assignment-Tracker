import SwiftUI

#if canImport(UIKit)
import UIKit
typealias PlatformColor = UIColor
#else
import AppKit
typealias PlatformColor = NSColor
#endif

extension Color {
    /// Adapts to light/dark mode.
    init(light: UInt32, dark: UInt32) {
        func c(_ h: UInt32) -> PlatformColor {
            PlatformColor(red: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: 1)
        }
        #if canImport(UIKit)
        self.init(UIColor { $0.userInterfaceStyle == .dark ? c(dark) : c(light) })
        #else
        self.init(NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? c(dark) : c(light) })
        #endif
    }
}

/// Calm-paper palette: warm neutrals, muted course colors, terracotta reserved for "this won't fit".
enum Theme {
    static let paper = Color(light: 0xFAF7F2, dark: 0x1B1815)
    static let ink = Color(light: 0x2B2724, dark: 0xF2EDE6)
    static let muted = Color(light: 0x8A8178, dark: 0x9A9087)
    static let hairline = Color(light: 0xE3DCD1, dark: 0x332E29)
    static let chip = Color(light: 0xEFE9E0, dark: 0x2A2622)
    static let warn = Color(light: 0xC2573A, dark: 0xE27B5E)
    static let slate = Color(light: 0x5E7A93, dark: 0x8FA9C0)

    private static let courseColors = [
        Color(light: 0x6F8F72, dark: 0x8FB092), slate,
        Color(light: 0xB98A3E, dark: 0xD6AC63), Color(light: 0x8A6A8F, dark: 0xB08DB5),
    ]
    /// Stable per course (String.hashValue changes every launch).
    static func accent(for course: String?) -> Color {
        courseColors[Int((course ?? "").unicodeScalars.reduce(0) { $0 + $1.value }) % courseColors.count]
    }
}

extension Text {
    /// Bold, tightly tracked sans for titles.
    func display(_ size: CGFloat) -> some View {
        font(.system(size: size, weight: .bold)).tracking(-size * 0.025)
    }
}

extension View {
    /// Paper background for Form sheets.
    func paperForm() -> some View { scrollContentBackground(.hidden).background(Theme.paper) }
}

/// Left-aligned chips that wrap onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxW: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > w, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height); maxW = max(maxW, x - spacing)
        }
        return CGSize(width: maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}
