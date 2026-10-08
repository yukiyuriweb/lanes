// Renders the app icon: swift scripts/make-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

// Rounded-square body with a drop shadow, per the macOS icon grid (824pt body on 1024 canvas).
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(bodyPath)
ctx.setFillColor(rgb(0x1B2233))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [rgb(0x2B3550), rgb(0x141A28)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
ctx.restoreGState()

let blue = rgb(0x4C8DFF), green = rgb(0x3DDC84), orange = rgb(0xFF9F43)
let line: CGFloat = 40

func stroke(_ color: CGColor, _ build: (CGMutablePath) -> Void) {
    let p = CGMutablePath()
    build(p)
    ctx.addPath(p)
    ctx.setStrokeColor(color)
    ctx.setLineWidth(line)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
}

// Curve from (x0, y0) to (x1, y1) with vertical tangents at both ends, like the in-app graph.
func bend(_ p: CGMutablePath, _ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) {
    let ym = (y0 + y1) / 2
    p.addCurve(to: CGPoint(x: x1, y: y1), control1: CGPoint(x: x0, y: ym), control2: CGPoint(x: x1, y: ym))
}

let mainX: CGFloat = 350, greenX: CGFloat = 530, orangeX: CGFloat = 690

// Branch lines first, so the main line sits on top where they join.
stroke(orange) { p in
    p.move(to: CGPoint(x: greenX, y: 430)); bend(p, greenX, 430, orangeX, 570)
    p.addLine(to: CGPoint(x: orangeX, y: 660))
}
stroke(green) { p in
    p.move(to: CGPoint(x: mainX, y: 240)); bend(p, mainX, 240, greenX, 380)
    p.addLine(to: CGPoint(x: greenX, y: 630)); bend(p, greenX, 630, mainX, 780)
}
stroke(blue) { p in
    p.move(to: CGPoint(x: mainX, y: 240)); p.addLine(to: CGPoint(x: mainX, y: 780))
}

func node(_ x: CGFloat, _ y: CGFloat, _ color: CGColor, hollow: Bool = false) {
    let r: CGFloat = 44
    let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
    ctx.setFillColor(rgb(0x1B2233))
    ctx.fillEllipse(in: rect.insetBy(dx: -12, dy: -12))
    ctx.setFillColor(color)
    ctx.fillEllipse(in: rect)
    if hollow {
        ctx.setFillColor(rgb(0x1B2233))
        ctx.fillEllipse(in: rect.insetBy(dx: 18, dy: 18))
    }
}

node(mainX, 240, blue)
node(mainX, 510, blue)
node(mainX, 780, blue, hollow: true)
node(greenX, 430, green)
node(greenX, 600, green)
node(orangeX, 660, orange)

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
