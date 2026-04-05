import AppKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let sizes = [16, 32, 64, 128, 256, 512, 1024]

func color(_ hex: String) -> NSColor {
    var value: UInt64 = 0
    Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
    return NSColor(
        calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: 1
    )
}

func drawIcon(size: Int) -> Data? {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let radius = CGFloat(size) * 0.22
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    NSGraphicsContext.current?.imageInterpolation = .high

    let gradient = NSGradient(starting: color("#1A1A2E"), ending: color("#16213E"))
    gradient?.draw(in: path, angle: 270)

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let font = NSFont.systemFont(ofSize: CGFloat(size) * 0.52, weight: .bold)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph
    ]

    let letter = NSAttributedString(string: "K", attributes: attributes)
    let letterSize = letter.size()
    let letterRect = NSRect(
        x: (rect.width - letterSize.width) / 2,
        y: (rect.height - letterSize.height) / 2 - CGFloat(size) * 0.03,
        width: letterSize.width,
        height: letterSize.height
    )
    letter.draw(in: letterRect)

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff) else {
        return nil
    }
    return bitmap.representation(using: .png, properties: [:])
}

let fileNames = [
    16: "icon_16x16.png",
    32: "icon_16x16@2x.png",
    64: "icon_32x32@2x.png",
    128: "icon_128x128.png",
    256: "icon_128x128@2x.png",
    512: "icon_256x256@2x.png",
    1024: "icon_512x512@2x.png"
]

let extraNames = [
    32: "icon_32x32.png",
    256: "icon_256x256.png",
    512: "icon_512x512.png"
]

try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for size in sizes {
    guard let data = drawIcon(size: size) else { continue }
    if let name = fileNames[size] {
        try data.write(to: outputDirectory.appendingPathComponent(name))
    }
    if let name = extraNames[size] {
        try data.write(to: outputDirectory.appendingPathComponent(name))
    }
}
