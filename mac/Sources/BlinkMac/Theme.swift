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

// MARK: - Blink visual DNA (lifted from the iOS fork tokens)

enum Theme {
    // Grounds
    static let bg      = Color(hex: 0x0b0c0e)   // page / terminal-black chrome
    static let term    = Color(hex: 0x101010)   // terminal body
    static let panel   = Color(hex: 0x14161b)
    static let panel2  = Color(hex: 0x16191d)
    static let panel3  = Color(hex: 0x1a1d23)
    static let line    = Color(hex: 0x1c2128)

    // Hairlines (white overlays)
    static let hair    = Color.white.opacity(0.08)
    static let hair2   = Color.white.opacity(0.14)
    static let fill    = Color.white.opacity(0.045)
    static let fill2   = Color.white.opacity(0.08)

    // Text
    static let fg      = Color(hex: 0xd4dae0)
    static let dim     = Color(hex: 0x6b7683)
    static let sub     = Color(hex: 0x8b95a5)

    // Accents
    static let green   = Color(hex: 0x33e0a1)   // send affordance
    static let green2  = Color(hex: 0x3fdc97)   // user / "you"
    static let blue    = Color(hex: 0x4ea8ff)   // assistant
    static let teal    = Color(hex: 0x63d3e8)
    static let cyan    = Color(hex: 0x3fdee9)    // cursor
    static let purple  = Color(hex: 0xb78cff)    // thinking / assistant chat

    // Status quartet
    static let wait    = Color(hex: 0xf5a83d)
    static let work    = Color(hex: 0x40d68c)
    static let idle    = Color(hex: 0x757f8f)
    static let rest    = Color(hex: 0x8f8cff)

    // Fonts
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}
