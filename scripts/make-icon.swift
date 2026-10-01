// Renders the app icon as a 1024×1024 PNG. Usage: swift make-icon.swift out.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}
func gradient(_ stops: [(Double, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: stops.map(\.1) as CFArray, locations: stops.map { CGFloat($0.0) })!
}

// Background tile: macOS icon grid (824pt tile centered in 1024 canvas), continuous-ish corners.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(color(0.05, 0.08, 0.2)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
ctx.drawLinearGradient(gradient([(0, color(0.03, 0.05, 0.16)), (0.55, color(0.06, 0.16, 0.42)), (1, color(0.12, 0.38, 0.85))]),
                       start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
// Soft blue laser glow behind the disc.
ctx.drawRadialGradient(gradient([(0, color(0.35, 0.65, 1, 0.55)), (1, color(0.35, 0.65, 1, 0))]),
                       startCenter: CGPoint(x: 512, y: 512), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 512), endRadius: 430, options: [])
ctx.restoreGState()

// Disc.
let c = CGPoint(x: 512, y: 512)
let rOuter = 330.0, rData = 318.0, rHub = 118.0, rHole = 46.0
func circle(_ r: Double) -> CGRect { CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2) }

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: color(0, 0, 0, 0.5))
ctx.setFillColor(color(0.75, 0.78, 0.85)); ctx.fillEllipse(in: circle(rOuter))
ctx.restoreGState()

// Recording surface: iridescent conic sweep, clipped to the ring between hub and edge.
ctx.saveGState()
let ring = CGMutablePath()
ring.addEllipse(in: circle(rData)); ring.addEllipse(in: circle(rHub))
ctx.addPath(ring); ctx.clip(using: .evenOdd)
let irid: [(Double, [Double])] = [
    (0.00, [0.55, 0.85, 1.00]), (0.12, [0.62, 0.55, 1.00]), (0.25, [0.95, 0.60, 0.95]),
    (0.37, [1.00, 0.85, 0.62]), (0.50, [0.70, 1.00, 0.85]), (0.62, [0.50, 0.80, 1.00]),
    (0.75, [0.65, 0.55, 1.00]), (0.87, [0.95, 0.65, 0.90]), (1.00, [0.55, 0.85, 1.00]),
]
func iridColor(_ t: Double) -> CGColor {
    let i = irid.lastIndex { $0.0 <= t } ?? 0
    let (t0, a) = irid[i], (t1, b) = irid[min(i + 1, irid.count - 1)]
    let f = t1 > t0 ? (t - t0) / (t1 - t0) : 0
    return color(a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f)
}
// CoreGraphics has no conic gradient: sweep thin overlapping wedges instead.
let wedges = 720
for k in 0..<wedges {
    let a0 = Double(k) / Double(wedges) * 2 * .pi + .pi / 5
    let a1 = a0 + 2 * .pi / Double(wedges) * 1.5
    ctx.move(to: c)
    ctx.addArc(center: c, radius: rData + 2, startAngle: a0, endAngle: a1, clockwise: false)
    ctx.closePath()
    ctx.setFillColor(iridColor(Double(k) / Double(wedges)))
    ctx.fillPath()
}
// Darken toward the centre for depth.
ctx.drawRadialGradient(gradient([(0, color(0.05, 0.1, 0.3, 0.55)), (1, color(0.05, 0.1, 0.3, 0))]),
                       startCenter: c, startRadius: rHub, endCenter: c, endRadius: rData, options: [])
// Session rings: each burned session is a band — the app's whole point.
ctx.setStrokeColor(color(1, 1, 1, 0.55)); ctx.setLineWidth(5)
for r in [175.0, 228.0, 270.0] { ctx.strokeEllipse(in: circle(r)) }
// Glossy highlight across the top-left.
ctx.drawLinearGradient(gradient([(0, color(1, 1, 1, 0.45)), (0.45, color(1, 1, 1, 0)), (1, color(1, 1, 1, 0))]),
                       start: CGPoint(x: 260, y: 780), end: CGPoint(x: 620, y: 420), options: [])
ctx.restoreGState()

// Clear hub + spindle hole.
ctx.setFillColor(color(0.86, 0.9, 0.97, 0.9)); ctx.fillEllipse(in: circle(rHub))
ctx.setStrokeColor(color(1, 1, 1, 0.7)); ctx.setLineWidth(3); ctx.strokeEllipse(in: circle(rHub - 22))
ctx.setBlendMode(.clear); ctx.fillEllipse(in: circle(rHole)); ctx.setBlendMode(.normal)
ctx.setFillColor(color(0.04, 0.07, 0.2)); ctx.fillEllipse(in: circle(rHole))

// "+" badge: add another session.
let badgeC = CGPoint(x: 760, y: 280), badgeR = 108.0
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: color(0, 0, 0, 0.45))
ctx.setFillColor(color(1, 0.42, 0.25))
ctx.fillEllipse(in: CGRect(x: badgeC.x - badgeR, y: badgeC.y - badgeR, width: badgeR * 2, height: badgeR * 2))
ctx.restoreGState()
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: badgeC.x - badgeR, y: badgeC.y - badgeR, width: badgeR * 2, height: badgeR * 2)); ctx.clip()
ctx.drawLinearGradient(gradient([(0, color(1, 0.62, 0.3)), (1, color(0.92, 0.25, 0.3))]),
                       start: CGPoint(x: badgeC.x, y: badgeC.y + badgeR), end: CGPoint(x: badgeC.x, y: badgeC.y - badgeR), options: [])
ctx.restoreGState()
ctx.setStrokeColor(color(1, 1, 1)); ctx.setLineWidth(30); ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: badgeC.x - 50, y: badgeC.y)); ctx.addLine(to: CGPoint(x: badgeC.x + 50, y: badgeC.y))
ctx.move(to: CGPoint(x: badgeC.x, y: badgeC.y - 50)); ctx.addLine(to: CGPoint(x: badgeC.x, y: badgeC.y + 50))
ctx.strokePath()

let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("Wrote \(out)")
