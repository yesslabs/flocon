// Dessine l'icône de Flocon et écrit AppIcon.icns. Usage : swift icon.swift
import AppKit

let size: CGFloat = 1024
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// carré arrondi aux proportions des icônes macOS
let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.addPath(tile); ctx.clip()
let sky = CGGradient(colorsSpace: nil, colors: [CGColor(red: 0.09, green: 0.12, blue: 0.36, alpha: 1),
                                                CGColor(red: 0.33, green: 0.55, blue: 0.95, alpha: 1)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])

// petits flocons du fond
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.55))
for (x, y, r) in [(230, 800, 14), (790, 760, 18), (300, 560, 10), (760, 480, 12), (200, 400, 16), (330, 230, 12), (700, 250, 15), (640, 850, 9), (830, 620, 8)] as [(CGFloat, CGFloat, CGFloat)] {
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}

// grand flocon à six branches
let c = CGPoint(x: 512, y: 512), arm: CGFloat = 250
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: CGColor(red: 0.03, green: 0.06, blue: 0.25, alpha: 0.45))
ctx.setLineWidth(40)
for i in 0..<6 {
    let a = CGFloat(i) * .pi / 3 + .pi / 2
    func pt(_ d: CGFloat, _ da: CGFloat = 0, _ side: CGFloat = 0) -> CGPoint {
        CGPoint(x: c.x + cos(a) * d + cos(a + da) * side, y: c.y + sin(a) * d + sin(a + da) * side)
    }
    ctx.move(to: c); ctx.addLine(to: pt(arm))
    for (d, len) in [(150, 80), (90, 55)] as [(CGFloat, CGFloat)] {   // barbes
        ctx.move(to: pt(d)); ctx.addLine(to: pt(d, .pi / 3.2, len))
        ctx.move(to: pt(d)); ctx.addLine(to: pt(d, -.pi / 3.2, len))
    }
}
ctx.strokePath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Flocon.iconset")
try? FileManager.default.removeItem(at: dir)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let master = dir.appendingPathComponent("icon_512x512@2x.png")
try! rep.representation(using: .png, properties: [:])!.write(to: master)
func run(_ args: [String]) { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = args; try! p.run(); p.waitUntilExit() }
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512)] {
    run(["sips", "-z", "\(px)", "\(px)", master.path, "--out", dir.appendingPathComponent("icon_\(name).png").path])
}
run(["iconutil", "-c", "icns", dir.path, "-o", "AppIcon.icns"])
// aperçu facultatif : swift icon.swift apercu.png
if CommandLine.arguments.count > 1 { try? FileManager.default.copyItem(at: master, to: URL(fileURLWithPath: CommandLine.arguments[1])) }
