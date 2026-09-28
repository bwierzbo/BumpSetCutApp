// RallyLab's app icon, drawn in code: a volleyball in a detection box with
// its label tag, on the BumpSetCut blues with an annotation grid.
//
//   swift scripts/rallylab_icon.swift /tmp/icon_1024.png
//   for s in 16 32 128 256 512; do
//     sips -z $s $s /tmp/icon_1024.png --out RallyLab/Assets.xcassets/AppIcon.appiconset/icon_${s}x${s}.png
//     sips -z $((s*2)) $((s*2)) /tmp/icon_1024.png --out RallyLab/Assets.xcassets/AppIcon.appiconset/icon_${s}x${s}@2x.png
//   done

import AppKit
import CoreGraphics

let S: CGFloat = 1024
let out = CommandLine.arguments[1]
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Flip to +Y down so coordinates read like a design file.
ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)
func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255,
            blue: CGFloat(h & 255) / 255, alpha: a)
}

// macOS icon grid: 824pt body, 100pt margin, soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(shape); ctx.setFillColor(rgb(0x14207A)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()
// Background: the BumpSetCut blues, deepened toward a lab navy.
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x3E8EF0), rgb(0x1D3BC4), rgb(0x0F1A6B)] as CFArray,
                    locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 924, y: 100), end: CGPoint(x: 100, y: 924), options: [])
// Annotation grid.
ctx.setStrokeColor(rgb(0xFFFFFF, 0.07)); ctx.setLineWidth(3)
var g: CGFloat = 100 + 824 / 8
while g < 924 {
    ctx.move(to: CGPoint(x: g, y: 100)); ctx.addLine(to: CGPoint(x: g, y: 924))
    ctx.move(to: CGPoint(x: 100, y: g)); ctx.addLine(to: CGPoint(x: 924, y: g))
    g += 824 / 8
}
ctx.strokePath()
// A dotted ball trajectory arcing into the box.
ctx.setFillColor(rgb(0xFFFFFF, 0.28))
for i in 0..<7 {
    let t = CGFloat(i) / 6
    let x = 170 + t * 250, y = 760 - 330 * (1 - pow(1 - t, 2)) + t * 40
    let r = 7 + t * 5
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}
ctx.restoreGState()

// The ball.
let c = CGPoint(x: 560, y: 520), R: CGFloat = 205
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 30, color: rgb(0x050A30, 0.45))
ctx.setFillColor(rgb(0xEAF3FF)); ctx.fillEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
ctx.restoreGState()
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R)); ctx.clip()
let ballShade = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF), rgb(0xCFE2FF), rgb(0x8FB4F5)] as CFArray,
                           locations: [0, 0.6, 1])!
ctx.drawRadialGradient(ballShade, startCenter: CGPoint(x: c.x - 70, y: c.y - 80), startRadius: 10,
                       endCenter: c, endRadius: R * 1.05, options: [.drawsAfterEndLocation])
// Seams: the system volleyball symbol, drawn over the shaded ball.
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
let config = NSImage.SymbolConfiguration(pointSize: R * 1.62, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(srgbRed: 0.1, green: 0.18, blue: 0.66, alpha: 1)]))
let symbol = NSImage(systemSymbolName: "volleyball", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
let sz = symbol.size
let scale = (2 * R * 1.1) / max(sz.width, sz.height)
let rect = CGRect(x: c.x - sz.width * scale / 2, y: c.y - sz.height * scale / 2,
                  width: sz.width * scale, height: sz.height * scale)
symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
ctx.restoreGState()
ctx.setStrokeColor(rgb(0x1A2FA8, 0)); ctx.setLineWidth(10)
ctx.strokeEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))

// Detection box: corner brackets + handles, in the annotation orange.
let orange = rgb(0xFF9F1A)
let box = CGRect(x: c.x - R - 40, y: c.y - R - 40, width: 2 * R + 80, height: 2 * R + 80)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.45)); ctx.setLineWidth(6); ctx.setLineDash(phase: 0, lengths: [22, 16])
ctx.stroke(box)
ctx.setLineDash(phase: 0, lengths: [])
ctx.setStrokeColor(orange); ctx.setLineWidth(22); ctx.setLineCap(.round); ctx.setLineJoin(.round)
let L: CGFloat = 92
for (x, y, dx, dy) in [(box.minX, box.minY, 1.0, 1.0), (box.maxX, box.minY, -1.0, 1.0),
                       (box.minX, box.maxY, 1.0, -1.0), (box.maxX, box.maxY, -1.0, -1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
    ctx.move(to: CGPoint(x: x, y: y + dy * L)); ctx.addLine(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x + dx * L, y: y))
}
ctx.strokePath()

// Label tag on the box's top edge.
let tag = CGRect(x: box.minX - 11, y: box.minY - 92, width: 250, height: 76)
ctx.addPath(CGPath(roundedRect: tag, cornerWidth: 20, cornerHeight: 20, transform: nil))
ctx.setFillColor(orange); ctx.fillPath()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
let text = NSAttributedString(string: "ball 0.97", attributes: [
    .font: NSFont.systemFont(ofSize: 46, weight: .heavy),
    .foregroundColor: NSColor(srgbRed: 0.12, green: 0.1, blue: 0.3, alpha: 1)])
let size = text.size()
text.draw(at: CGPoint(x: tag.midX - size.width / 2, y: tag.midY - size.height / 2))

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
