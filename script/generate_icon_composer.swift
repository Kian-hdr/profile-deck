import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift script/generate_icon_composer.swift REPOSITORY_ROOT")
}

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let icon = root.appendingPathComponent("ProfileDeck/AppIcon.icon", isDirectory: true)
let assets = icon.appendingPathComponent("Assets", isDirectory: true)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

func drawLayer(_ name: String, body: () -> Void) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024,
        pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
    body()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!
        .write(to: assets.appendingPathComponent(name))
}

let cards: [(String, CGFloat, NSColor)] = [
    ("Back-Card-1024.png", 104, NSColor(srgbRed: 0.15, green: 0.29, blue: 0.49, alpha: 1)),
    ("Middle-Card-1024.png", 52, NSColor(srgbRed: 0.23, green: 0.41, blue: 0.66, alpha: 1)),
    ("Front-Card-1024.png", 0, NSColor(srgbRed: 0.34, green: 0.61, blue: 0.91, alpha: 1)),
]

for (index, card) in cards.enumerated() {
    try drawLayer(card.0) {
        card.2.setFill()
        NSBezierPath(roundedRect: NSRect(x: 230 + card.1, y: 222 + card.1,
            width: 504, height: 440), xRadius: 66, yRadius: 66).fill()
        guard index == 2 else { return }
        NSColor(srgbRed: 0.05, green: 0.11, blue: 0.20, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 301, y: 433, width: 100, height: 100)).fill()
        NSBezierPath(roundedRect: NSRect(x: 285, y: 328, width: 132, height: 76),
            xRadius: 38, yRadius: 38).fill()
        NSBezierPath(roundedRect: NSRect(x: 468, y: 465, width: 175, height: 24),
            xRadius: 12, yRadius: 12).fill()
        NSBezierPath(roundedRect: NSRect(x: 468, y: 402, width: 132, height: 24),
            xRadius: 12, yRadius: 12).fill()
    }
}

let groups = zip(["Front card", "Middle card", "Back card"], cards.reversed()).map { name, card in
    ["name": name, "layers": [["name": name, "image-name": card.0]]]
}
let document: [String: Any] = [
    "fill": ["solid": "extended-srgb:0.07000,0.09500,0.16000,1.00000"],
    "groups": groups,
    "supported-platforms": ["squares": "shared", "circles": ["watchOS"]],
]
try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    .write(to: icon.appendingPathComponent("icon.json"))
print("Generated editable three-layer Icon Composer source: \(icon.path)")
