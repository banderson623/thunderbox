// Thunderbox app icon generator — flat, bold, legible at every size.
//
// Design: a simplified outhouse (the "thunderbox") under a big amber lightning
// bolt on a deep-indigo rounded tile, matching the app's in-window theme. At
// 32 px and below the outhouse is dropped and only the bolt remains — small
// icons need one shape, not a scene.
//
// Usage:
//   swift assets/gen-icon.swift <out.png> [pixelSize]     one PNG (default 1024)
//   swift assets/gen-icon.swift --iconset <dir>           full .iconset worth of PNGs
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let colorSpace = CGColorSpaceCreateDeviceRGB()

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [
        CGFloat((hex >> 16) & 0xFF) / 255,
        CGFloat((hex >> 8) & 0xFF) / 255,
        CGFloat(hex & 0xFF) / 255, a])!
}

// Palette — drawn from Views/Theme.swift so the icon and the app agree.
let bgTop      = rgb(0x2B3148)   // lifted slate blue
let bgBottom   = rgb(0x131728)   // deep indigo
let wood       = rgb(0xA06B3C)   // warm cedar
let woodDark   = rgb(0x7C4F2A)   // roof / shading
let doorDark   = rgb(0x53351E)   // door recess
let amber      = rgb(0xFFC24A)   // brass / lightning
let amberDeep  = rgb(0xE59A1F)   // bolt shading edge
let haloDark   = rgb(0x131728)   // separates bolt from house

/// The classic zig-zag bolt as a polygon in a unit box (y-up).
let boltUnit: [CGPoint] = [
    CGPoint(x: 0.58, y: 1.00), CGPoint(x: 0.10, y: 0.42), CGPoint(x: 0.40, y: 0.42),
    CGPoint(x: 0.28, y: 0.00), CGPoint(x: 0.90, y: 0.56), CGPoint(x: 0.55, y: 0.56),
]

func path(_ points: [CGPoint], in box: CGRect) -> CGPath {
    let p = CGMutablePath()
    let mapped = points.map { CGPoint(x: box.minX + $0.x * box.width,
                                      y: box.minY + $0.y * box.height) }
    p.addLines(between: mapped)
    p.closeSubpath()
    return p
}

func render(pixels: Int, to url: URL) {
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels,
                              bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("no context") }
    let S = CGFloat(pixels)
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * S, y: y * S) }
    func box(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
        CGRect(x: x0 * S, y: y0 * S, width: (x1 - x0) * S, height: (y1 - y0) * S)
    }

    // Rounded-square tile with a vertical indigo gradient.
    let tile = CGPath(roundedRect: CGRect(x: 0, y: 0, width: S, height: S),
                      cornerWidth: S * 0.225, cornerHeight: S * 0.225, transform: nil)
    ctx.addPath(tile); ctx.clip()
    let grad = CGGradient(colorsSpace: colorSpace,
                          colors: [bgTop, bgBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: pt(0, 1), end: pt(0, 0), options: [])

    let simplified = pixels <= 32

    if !simplified {
        // Soft glow behind the scene so the tile isn't flat black.
        let glow = CGGradient(colorsSpace: colorSpace,
                              colors: [rgb(0xFFC24A, 0.14), rgb(0xFFC24A, 0)] as CFArray,
                              locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: pt(0.46, 0.50), startRadius: 0,
                               endCenter: pt(0.46, 0.50), endRadius: S * 0.52, options: [])

        // Outhouse, flat front — tall & narrow, overhanging roof, recessed door,
        // crescent moon. Proportions matter: squat reads "barn", tall reads "outhouse".
        ctx.setFillColor(wood)
        ctx.fill(box(0.20, 0.10, 0.58, 0.62))
        ctx.setFillColor(woodDark)                      // roof
        let roof = CGMutablePath()
        roof.addLines(between: [pt(0.13, 0.60), pt(0.65, 0.60), pt(0.39, 0.84)])
        roof.closeSubpath()
        ctx.addPath(roof); ctx.fillPath()
        ctx.setFillColor(doorDark)                      // door
        let door = CGPath(roundedRect: box(0.29, 0.13, 0.49, 0.54),
                          cornerWidth: S * 0.02, cornerHeight: S * 0.02, transform: nil)
        ctx.addPath(door); ctx.fillPath()
        ctx.setFillColor(amber)                         // crescent moon on the door
        ctx.fillEllipse(in: box(0.355, 0.42, 0.425, 0.49))
        ctx.setFillColor(doorDark)
        ctx.fillEllipse(in: box(0.368, 0.432, 0.438, 0.502))
    }

    // The bolt — the one shape every size shares.
    let boltBox = simplified
        ? box(0.20, 0.10, 0.84, 0.92)                   // alone: fill the tile
        : box(0.44, 0.10, 0.96, 0.94)                   // with house: strike beside it
    let bolt = path(boltUnit, in: boltBox)

    if !simplified {
        // Dark halo so the bolt separates cleanly from the house behind it.
        ctx.addPath(bolt)
        ctx.setLineWidth(S * 0.045)
        ctx.setLineJoin(.miter)
        ctx.setStrokeColor(haloDark)
        ctx.strokePath()
    }
    ctx.addPath(bolt)
    ctx.setFillColor(amber)
    ctx.fillPath()
    // A darker inner edge on the lower-left, for a hint of depth (skip when tiny).
    if pixels >= 64 {
        ctx.saveGState()
        ctx.addPath(bolt); ctx.clip()
        ctx.addPath(path(boltUnit, in: boltBox.offsetBy(dx: S * 0.018, dy: S * 0.014)))
        ctx.setFillColor(amberDeep)
        ctx.fillPath()
        ctx.restoreGState()
        // Re-fill the top-lit face.
        ctx.saveGState()
        ctx.addPath(path(boltUnit, in: boltBox.insetBy(dx: S * 0.018, dy: S * 0.016)
            .offsetBy(dx: -S * 0.004, dy: S * 0.006)))
        ctx.setFillColor(amber)
        ctx.fillPath()
        ctx.restoreGState()
    }

    guard let img = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil)
    else { fatalError("write \(url.path)") }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(url.path) (\(pixels)px)")
}

let args = CommandLine.arguments
if args.count >= 3, args[1] == "--iconset" {
    let dir = URL(fileURLWithPath: args[2], isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for sz in [16, 32, 64, 128, 256, 512] {
        render(pixels: sz, to: dir.appendingPathComponent("icon_\(sz)x\(sz).png"))
        render(pixels: sz * 2, to: dir.appendingPathComponent("icon_\(sz)x\(sz)@2x.png"))
    }
} else {
    let out = args.count > 1 ? args[1] : "assets/icon.png"
    let size = args.count > 2 ? Int(args[2]) ?? 1024 : 1024
    render(pixels: size, to: URL(fileURLWithPath: out))
}
