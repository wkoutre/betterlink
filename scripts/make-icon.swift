// Draws betterlink's app icon: one link becoming two paths.
// Usage: swift make-icon.swift <out.png> [size]
import AppKit
import CoreGraphics

let args = CommandLine.arguments
let out = args[1]
let size = CGFloat(args.count > 2 ? Double(args[2])! : 1024)
let s = size / 1024

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: s, y: s)
// Flip so y grows downward, like a design tool.
ctx.translateBy(x: 0, y: 1024); ctx.scaleBy(x: 1, y: -1)

// macOS icon grid: an 824pt rounded square centered on the 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Soft shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x1F2A44, 0.22))
ctx.addPath(tilePath); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
ctx.restoreGState()

// Airy background: white at the top to a pale sky at the bottom.
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF), rgb(0xEAF1FD)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
// A faint light pool behind the fork.
let glow = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.9), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 470, y: 470), startRadius: 0, endCenter: CGPoint(x: 470, y: 470), endRadius: 420, options: [])
ctx.restoreGState()

// Hairline edge.
ctx.addPath(tilePath); ctx.setStrokeColor(rgb(0xD6E0EF)); ctx.setLineWidth(3); ctx.strokePath()

// The fork.
let origin = CGPoint(x: 300, y: 512)
let split = CGPoint(x: 470, y: 512)
func branch(to end: CGPoint, color: UInt32) {
    let p = CGMutablePath()
    p.move(to: split)
    p.addCurve(to: end, control1: CGPoint(x: split.x + 120, y: split.y), control2: CGPoint(x: end.x - 150, y: end.y))
    // Each path keeps to its own side of the split, so they meet on a clean line.
    ctx.saveGState()
    ctx.clip(to: end.y < split.y ? CGRect(x: 0, y: 0, width: 1024, height: split.y)
                                 : CGRect(x: 0, y: split.y, width: 1024, height: 1024 - split.y))
    ctx.addPath(p)
    ctx.setStrokeColor(rgb(color)); ctx.setLineWidth(62); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()
    // Path ends in a small ring: a destination.
    ctx.setFillColor(rgb(color)); ctx.fillEllipse(in: CGRect(x: end.x - 46, y: end.y - 46, width: 92, height: 92))
    ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillEllipse(in: CGRect(x: end.x - 20, y: end.y - 20, width: 40, height: 40))
}
branch(to: CGPoint(x: 740, y: 344), color: 0x4C8DF6)   // sky
branch(to: CGPoint(x: 740, y: 680), color: 0xF6836F)   // coral
// The shared stem drawn last, in ink, so the split reads as one link becoming two.
ctx.setStrokeColor(rgb(0x1F2A44)); ctx.setLineWidth(62); ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: origin.x, y: origin.y)); ctx.addLine(to: CGPoint(x: split.x, y: split.y)); ctx.strokePath()
ctx.setFillColor(rgb(0x1F2A44)); ctx.fillEllipse(in: CGRect(x: origin.x - 62, y: origin.y - 62, width: 124, height: 124))

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
