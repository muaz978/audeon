import AppKit
import CoreGraphics
import Foundation

// Draws the Audeon icon: a routing graph (source nodes on the left connected by
// cables to destination nodes on the right) on a blue to purple gradient tile,
// echoing the app's two column routing canvas. Rendered fresh at each size for
// crisp results from 16 px up to 1024 px.

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a).cgColor
}

func drawDesign(_ ctx: CGContext) {
    // Work in a 1024 x 1024 space, Core Graphics origin at bottom left.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let radius: CGFloat = 185
    let tile = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Soft drop shadow for the rounded tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 40,
                  color: NSColor(white: 0, alpha: 0.32).cgColor)
    ctx.addPath(tile); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    // Gradient fill, clipped to the tile.
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let grad = CGGradient(colorsSpace: space,
                          colors: [rgb(58, 132, 246), rgb(101, 102, 232), rgb(140, 80, 232)] as CFArray,
                          locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: 220, y: 924),
                           end: CGPoint(x: 824, y: 120),
                           options: [])
    // Subtle top gloss.
    let gloss = CGGradient(colorsSpace: space,
                           colors: [NSColor(white: 1, alpha: 0.18).cgColor,
                                    NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(gloss,
                           start: CGPoint(x: 512, y: 924),
                           end: CGPoint(x: 512, y: 560),
                           options: [])
    ctx.restoreGState()

    // Routing graph.
    let leftX: CGFloat = 352, rightX: CGFloat = 672
    let ys: [CGFloat] = [384, 512, 640]
    let dotR: CGFloat = 34, glowR: CGFloat = 62
    let lineW: CGFloat = 26

    // Cables first so the nodes sit on top. Each cable bows a little for a woven look.
    ctx.setLineCap(.round)
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.95).cgColor)
    ctx.setLineWidth(lineW)
    for i in 0..<3 {
        let ly = ys[i], ry = ys[i]
        let bow: CGFloat = CGFloat(i - 1) * 34
        let d = rightX - leftX
        let p = CGMutablePath()
        p.move(to: CGPoint(x: leftX, y: ly))
        p.addCurve(to: CGPoint(x: rightX, y: ry),
                   control1: CGPoint(x: leftX + d * 0.45, y: ly + bow),
                   control2: CGPoint(x: rightX - d * 0.45, y: ry - bow))
        ctx.addPath(p); ctx.strokePath()
    }
    // One crossing cable to suggest mixing and routing flexibility.
    let cross = CGMutablePath()
    cross.move(to: CGPoint(x: leftX, y: ys[0]))
    cross.addCurve(to: CGPoint(x: rightX, y: ys[2]),
                   control1: CGPoint(x: 512, y: ys[0]),
                   control2: CGPoint(x: 512, y: ys[2]))
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.55).cgColor)
    ctx.addPath(cross); ctx.strokePath()

    // Nodes with a soft glow.
    for x in [leftX, rightX] {
        for y in ys {
            ctx.setFillColor(NSColor(white: 1, alpha: 0.20).cgColor)
            ctx.fillEllipse(in: CGRect(x: x - glowR, y: y - glowR, width: glowR * 2, height: glowR * 2))
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: x - dotR, y: y - dotR, width: dotR * 2, height: dotR * 2))
        }
    }
}

func render(px: Int, to url: URL) {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px) / 1024.0
    ctx.scaleBy(x: s, y: s)
    drawDesign(ctx)
    let img = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: img)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = out.appendingPathComponent("Audeon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    render(px: px, to: iconset.appendingPathComponent("\(name).png"))
}
render(px: 1024, to: out.appendingPathComponent("Audeon-icon-1024.png"))
print("rendered iconset and 1024 preview")
