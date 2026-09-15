import SwiftUI

// MARK: - Color helpers

extension Color {
    /// Init from 0xRRGGBB.
    init(hex: UInt, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

// MARK: - Blink visual DNA（沿用 BlinkMac 的 token）

enum Theme {
    static let bg      = Color(hex: 0x0b0c0e)
    static let panel   = Color(hex: 0x14161b)
    static let panel2  = Color(hex: 0x16191d)
    static let panel3  = Color(hex: 0x1a1d23)

    static let hair    = Color.white.opacity(0.08)
    static let hair2   = Color.white.opacity(0.14)
    static let fill    = Color.white.opacity(0.045)

    static let fg      = Color(hex: 0xd4dae0)
    static let dim     = Color(hex: 0x6b7683)
    static let sub     = Color(hex: 0x8b95a5)

    static let green   = Color(hex: 0x33e0a1)
    static let green2  = Color(hex: 0x3fdc97)
    static let blue    = Color(hex: 0x4ea8ff)
    static let teal    = Color(hex: 0x63d3e8)
    static let red     = Color(hex: 0xff5a5f)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}
