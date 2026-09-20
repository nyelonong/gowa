// Generates AppIcon.icns: rounded-square gradient with a white paper plane.
// Run: swift scripts/make-icon.swift
import AppKit

let size = 1024
let outputDirectory = URL(fileURLWithPath: "AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: outputDirectory)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func renderMaster() -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let inset = CGFloat(102)
    let rect = NSRect(x: inset, y: inset, width: CGFloat(size) - inset * 2, height: CGFloat(size) - inset * 2)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: 230, yRadius: 230)

    squircle.setClip()

    let gradient = NSGradient(
        colors: [
            NSColor(red: 0.07, green: 0.10, blue: 0.16, alpha: 1),
            NSColor(red: 0.04, green: 0.55, blue: 0.47, alpha: 1),
        ]
    )
    gradient?.draw(in: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height), angle: -70)

    // Subtle highlight: translucent diagonal sheen.
    NSColor(white: 1, alpha: 0.06).setFill()
    NSBezierPath(rect: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)).fill()

    // Paper plane glyph (SF Symbol), tinted white.
    let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold)
    let symbol = NSImage(
        systemSymbolName: "paperplane.fill",
        accessibilityDescription: nil
    )!
        .withSymbolConfiguration(config)!

    let mask = NSImage(size: symbol.size)
    mask.lockFocus()
    symbol.draw(
        in: NSRect(origin: .zero, size: symbol.size),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )
    NSColor.white.set()
    NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
    mask.unlockFocus()

    let glyphSize = CGFloat(620)
    let glyphRect = NSRect(
        x: (CGFloat(size) - glyphSize) / 2,
        y: (CGFloat(size) - glyphSize) / 2,
        width: glyphSize,
        height: glyphSize
    )
    mask.draw(
        in: glyphRect,
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )

    image.unlockFocus()
    return image
}

let master = renderMaster()
guard let tiff = master.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write(Data("icon render failed\n".utf8))
    exit(1)
}

let masterFile = outputDirectory.appendingPathComponent("icon_512x512@2x.png")
try png.write(to: masterFile)

// iconset members
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
]

for (pixels, name) in sizes {
    let destination = outputDirectory.appendingPathComponent(name)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    process.arguments = ["-z", "\(pixels)", "\(pixels)", masterFile.path, "--out", destination.path]
    try process.run()
    process.waitUntilExit()
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", outputDirectory.path, "-o", "AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()

print("AppIcon.icns written")
