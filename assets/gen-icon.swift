// Renders a 1024×1024 placeholder app icon to assets/icon.png.
// Used only when no real icon.png is present. Run: swift assets/gen-icon.swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

let size = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("ctx")
}
let S = CGFloat(size)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}

// Rounded-rect background with a vertical gradient (dark slate → near-black).
let radius: CGFloat = S * 0.225
let rect = CGRect(x: 0, y: 0, width: S, height: S)
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.addPath(path); ctx.clip()

let grad = CGGradient(colorsSpace: cs,
                      colors: [color(0.16, 0.18, 0.22), color(0.06, 0.07, 0.09)] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])

// Soft inner vignette.
let vig = CGGradient(colorsSpace: cs,
                     colors: [color(0.3, 0.55, 0.35, 0.10), color(0, 0, 0, 0)] as CFArray,
                     locations: [0, 1])!
ctx.drawRadialGradient(vig, startCenter: CGPoint(x: S*0.5, y: S*0.62), startRadius: 0,
                       endCenter: CGPoint(x: S*0.5, y: S*0.62), endRadius: S*0.6, options: [])

// Terminal prompt ">_" in phosphor green, drawn with AppKit text.
let nsImage = NSImage(size: NSSize(width: size, height: size))
let gctx = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.current = gctx
_ = nsImage

let font = NSFont.monospacedSystemFont(ofSize: S * 0.30, weight: .bold)
let green = NSColor(calibratedRed: 0.42, green: 0.92, blue: 0.48, alpha: 1)
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: green]
let prompt = NSAttributedString(string: ">_", attributes: attrs)
let ps = prompt.size()
prompt.draw(at: NSPoint(x: (S - ps.width)/2, y: (S - ps.height)/2 * 1.02))

// A small lightning bolt accent, top-right.
ctx.setFillColor(color(1.0, 0.83, 0.25, 1))
let bx = S * 0.72, by = S * 0.70, bw = S * 0.16, bh = S * 0.20
let bolt = CGMutablePath()
bolt.move(to: CGPoint(x: bx + bw*0.55, y: by + bh))
bolt.addLine(to: CGPoint(x: bx, y: by + bh*0.42))
bolt.addLine(to: CGPoint(x: bx + bw*0.42, y: by + bh*0.42))
bolt.addLine(to: CGPoint(x: bx + bw*0.30, y: by))
bolt.addLine(to: CGPoint(x: bx + bw, y: by + bh*0.60))
bolt.addLine(to: CGPoint(x: bx + bw*0.55, y: by + bh*0.60))
bolt.closeSubpath()
ctx.addPath(bolt); ctx.fillPath()

guard let img = ctx.makeImage() else { fatalError("img") }
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/icon.png"
let url = URL(fileURLWithPath: outPath)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("dest") }
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outPath)")
