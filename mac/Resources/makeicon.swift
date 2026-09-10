import AppKit

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

func col(_ hex: UInt) -> NSColor {
    NSColor(srgbRed: CGFloat((hex>>16)&0xFF)/255, green: CGFloat((hex>>8)&0xFF)/255, blue: CGFloat(hex&0xFF)/255, alpha: 1)
}

// rounded-rect background with gradient
let inset: CGFloat = 0
let rect = NSRect(x: inset, y: inset, width: S-2*inset, height: S-2*inset)
let radius: CGFloat = 230
let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
path.addClip()
let grad = NSGradient(colors: [col(0x232f3d), col(0x0c0e12), col(0x08090b)],
                      atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
grad.draw(in: rect, angle: -90)

// inner hairline border
let border = NSBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 6), xRadius: radius-6, yRadius: radius-6)
border.lineWidth = 3
col(0xffffff).withAlphaComponent(0.10).setStroke()
border.stroke()

// terminal prompt  >█ , centered as a group
let mono = NSFont.monospacedSystemFont(ofSize: 440, weight: .bold)
let wChevron = NSAttributedString(string: ">", attributes: [.font: mono]).size().width
let wCursor = NSAttributedString(string: "█", attributes: [.font: mono]).size().width
let gap: CGFloat = 46
let groupW = wChevron + gap + wCursor
let startX = (S - groupW) / 2
let baseY = (S - NSAttributedString(string: ">", attributes: [.font: mono]).size().height) / 2 + 20

func draw(_ s: String, _ color: NSColor, x: CGFloat) {
    NSAttributedString(string: s, attributes: [.font: mono, .foregroundColor: color]).draw(at: NSPoint(x: x, y: baseY))
}
ctx.setShadow(offset: .zero, blur: 42, color: col(0x33e0a1).withAlphaComponent(0.45).cgColor)
draw(">", col(0x33e0a1), x: startX)
ctx.setShadow(offset: .zero, blur: 48, color: col(0x3fdee9).withAlphaComponent(0.55).cgColor)
draw("█", col(0x3fdee9), x: startX + wChevron + gap)

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/blinkmac-icon.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
