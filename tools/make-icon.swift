// Draws the SpinBreak icon and writes SpinBreak.icns next to the sources.
//   swift tools/make-icon.swift
// The picture is the app's own best moment: the reel has stopped, and the pick (a tomato, for the pomodoro this
// started as) pops out of the bright middle row in a little burst.
import AppKit

let S: CGFloat = 1024
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
let mint = rgb(0.31, 0.82, 0.65), coral = rgb(1, 0.48, 0.35), ink = rgb(0.08, 0.07, 0.10)

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

/// The macOS icon shape: a superellipse, 824 points across on a 1024 canvas.
func squircle(_ half: CGFloat = 412, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath(), c = S / 2
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi, ct = cos(t), st = sin(t)
        let pt = CGPoint(x: c + half * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n), y: c + half * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n))
        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    p.closeSubpath(); return p
}
func pill(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }
func gradient(_ colors: [CGColor], _ stops: [CGFloat]) -> CGGradient { CGGradient(colorsSpace: space, colors: colors as CFArray, locations: stops)! }

// Shadow under the tile, then the tile itself: the app's night-sky background.
let shape = squircle()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: rgb(0, 0, 0, 0.35))
ctx.addPath(shape); ctx.setFillColor(ink); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0.13, 0.10, 0.19), rgb(0.04, 0.15, 0.13)], [0, 1]), start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])

// Light rays from the middle, as on the spin.
let mid = CGPoint(x: S / 2, y: S / 2)
for i in 0..<16 {
    let a = CGFloat(i) / 16 * 2 * .pi + 0.2, w = CGFloat.pi / 16 * 0.5
    ctx.move(to: mid)
    ctx.addLine(to: CGPoint(x: mid.x + cos(a - w) * 900, y: mid.y + sin(a - w) * 900))
    ctx.addLine(to: CGPoint(x: mid.x + cos(a + w) * 900, y: mid.y + sin(a + w) * 900))
    ctx.closePath(); ctx.setFillColor(i % 2 == 0 ? rgb(0.31, 0.82, 0.65, 0.10) : rgb(1, 0.48, 0.35, 0.08)); ctx.fillPath()
}
ctx.drawRadialGradient(gradient([rgb(1, 0.55, 0.4, 0.30), rgb(1, 0.55, 0.4, 0)], [0, 1]), startCenter: mid, startRadius: 0, endCenter: mid, endRadius: 420, options: [])

// The rows above and below the one that won: dimmer and a little smaller, on their way off the screen.
func row(y: CGFloat, width: CGFloat, alpha: CGFloat) {
    let h: CGFloat = 104, r = CGRect(x: mid.x - width / 2, y: y - h / 2, width: width, height: h)
    ctx.addPath(pill(r, 34)); ctx.setFillColor(rgb(1, 1, 1, 0.10 * alpha)); ctx.fillPath()
    ctx.addPath(pill(r, 34)); ctx.setStrokeColor(rgb(1, 1, 1, 0.22 * alpha)); ctx.setLineWidth(5); ctx.strokePath()
    ctx.setFillColor(rgb(1, 1, 1, 0.34 * alpha)); ctx.fillEllipse(in: CGRect(x: r.minX + 34, y: y - 24, width: 48, height: 48))
    ctx.addPath(pill(CGRect(x: r.minX + 108, y: y - 12, width: width * 0.48, height: 24), 12)); ctx.setFillColor(rgb(1, 1, 1, 0.26 * alpha)); ctx.fillPath()
}
row(y: mid.y + 238, width: 500, alpha: 0.9); row(y: mid.y - 238, width: 500, alpha: 0.9)
row(y: mid.y + 372, width: 420, alpha: 0.45); row(y: mid.y - 372, width: 420, alpha: 0.45)

// The window the reel stops in, with a pointer either side.
let frame = CGRect(x: mid.x - 318, y: mid.y - 118, width: 636, height: 236)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 46, color: rgb(0.31, 0.82, 0.65, 0.9))
ctx.addPath(pill(frame, 72)); ctx.setStrokeColor(rgb(1, 1, 1, 0.96)); ctx.setLineWidth(16); ctx.strokePath()
ctx.restoreGState()
ctx.addPath(pill(frame, 72)); ctx.setFillColor(rgb(1, 1, 1, 0.07)); ctx.fillPath()
for dir in [CGFloat(-1), 1] {
    let x = mid.x + dir * 372
    ctx.move(to: CGPoint(x: x - dir * 30, y: mid.y)); ctx.addLine(to: CGPoint(x: x + dir * 22, y: mid.y + 36)); ctx.addLine(to: CGPoint(x: x + dir * 22, y: mid.y - 36))
    ctx.closePath(); ctx.setFillColor(coral); ctx.fillPath()
}

// Confetti from the reveal.
let bits: [(CGFloat, CGFloat, CGFloat, CGColor, CGFloat)] = [
    (-250, 150, 26, mint, 0.5), (236, 168, 22, rgb(1, 0.85, 0.3), -0.4), (-176, -168, 20, rgb(1, 0.85, 0.3), 0.9), (262, -150, 26, mint, 0.2),
    (-292, -40, 16, rgb(1, 1, 1, 0.9), 0.3), (300, 36, 18, rgb(1, 1, 1, 0.9), -0.7), (120, 196, 16, coral, 0.6), (-96, 204, 18, rgb(1, 1, 1, 0.9), -0.2),
    (150, -196, 18, rgb(1, 1, 1, 0.9), 0.4), (-40, -206, 16, coral, -0.5)]
for (dx, dy, size, colour, turn) in bits {
    ctx.saveGState(); ctx.translateBy(x: mid.x + dx, y: mid.y + dy); ctx.rotate(by: turn)
    ctx.addPath(pill(CGRect(x: -size, y: -size / 2.4, width: size * 2, height: size / 1.2), size / 3)); ctx.setFillColor(colour); ctx.fillPath()
    ctx.restoreGState()
}

// The pick: a tomato, bigger than the window it landed in.
let R: CGFloat = 168, tom = CGPoint(x: mid.x, y: mid.y - 10)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: rgb(0, 0, 0, 0.45))
ctx.addEllipse(in: CGRect(x: tom.x - R * 1.06, y: tom.y - R * 0.94, width: R * 2.12, height: R * 1.88)); ctx.setFillColor(coral); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: tom.x - R * 1.06, y: tom.y - R * 0.94, width: R * 2.12, height: R * 1.88)); ctx.clip()
ctx.drawRadialGradient(gradient([rgb(1, 0.56, 0.40), rgb(0.96, 0.30, 0.22), rgb(0.78, 0.16, 0.14)], [0, 0.62, 1]),
                       startCenter: CGPoint(x: tom.x - 54, y: tom.y + 64), startRadius: 0, endCenter: tom, endRadius: R * 1.25, options: [.drawsAfterEndLocation])
ctx.setFillColor(rgb(1, 1, 1, 0.26)); ctx.fillEllipse(in: CGRect(x: tom.x - 112, y: tom.y + 40, width: 84, height: 50))
ctx.restoreGState()
// Its leaves: five mint points and a stalk.
let top = CGPoint(x: tom.x, y: tom.y + R * 0.80)
ctx.saveGState(); ctx.translateBy(x: top.x, y: top.y)
for i in 0..<5 {
    ctx.saveGState(); ctx.rotate(by: CGFloat(i) / 5 * 2 * .pi + 0.31)
    ctx.move(to: CGPoint(x: -20, y: 0)); ctx.addQuadCurve(to: CGPoint(x: 0, y: 94), control: CGPoint(x: -30, y: 52))
    ctx.addQuadCurve(to: CGPoint(x: 20, y: 0), control: CGPoint(x: 30, y: 52)); ctx.closePath()
    ctx.setFillColor(i % 2 == 0 ? mint : rgb(0.20, 0.66, 0.50)); ctx.fillPath()
    ctx.restoreGState()
}
ctx.restoreGState()
ctx.addPath(pill(CGRect(x: top.x - 13, y: top.y - 6, width: 26, height: 74), 13)); ctx.setFillColor(rgb(0.16, 0.56, 0.42)); ctx.fillPath()
ctx.restoreGState()

// Write every size macOS wants, then pack them.
let image = ctx.makeImage()!
let fm = FileManager.default, here = URL(fileURLWithPath: fm.currentDirectoryPath)
let set = fm.temporaryDirectory.appendingPathComponent("SpinBreak.iconset")
try? fm.removeItem(at: set); try! fm.createDirectory(at: set, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high; c.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
    let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent("icon_\(name).png"))
}
let pack = Process(); pack.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
pack.arguments = ["-c", "icns", set.path, "-o", here.appendingPathComponent("SpinBreak.icns").path]
try! pack.run(); pack.waitUntilExit()
print(pack.terminationStatus == 0 ? "Wrote SpinBreak.icns" : "iconutil failed")
