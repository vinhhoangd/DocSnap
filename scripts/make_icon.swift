// Draws the 1024×1024 app icon. Run: swift scripts/make_icon.swift <output.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
// App Store icons must be opaque, so draw into an RGB context with no alpha.
let cg = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

// Blue-violet gradient background.
let colors = [CGColor(red: 0.27, green: 0.45, blue: 1.0, alpha: 1), CGColor(red: 0.33, green: 0.20, blue: 0.80, alpha: 1)] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

// White page with a folded corner (y axis points up here).
let page = CGRect(x: 312, y: 232, width: 400, height: 540)
let fold: CGFloat = 110
let path = CGMutablePath()
path.move(to: CGPoint(x: page.minX, y: page.minY))
path.addLine(to: CGPoint(x: page.maxX, y: page.minY))
path.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
path.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY))
path.addLine(to: CGPoint(x: page.minX, y: page.maxY))
path.closeSubpath()
cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: CGColor(gray: 0, alpha: 0.3))
cg.setFillColor(CGColor(gray: 1, alpha: 1))
cg.addPath(path)
cg.fillPath()
cg.setShadow(offset: .zero, blur: 0, color: nil)
cg.setFillColor(CGColor(red: 0.85, green: 0.87, blue: 0.98, alpha: 1))
cg.move(to: CGPoint(x: page.maxX - fold, y: page.maxY))
cg.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY - fold))
cg.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
cg.closePath()
cg.fillPath()

// Text lines.
cg.setFillColor(CGColor(red: 0.30, green: 0.32, blue: 0.85, alpha: 0.5))
for (i, w) in [260.0, 300, 220, 290, 180].enumerated() {
    cg.fill(CGRect(x: page.minX + 50, y: page.maxY - 170 - CGFloat(i) * 70, width: w, height: 26))
}

// Viewfinder corner brackets.
cg.setStrokeColor(CGColor(gray: 1, alpha: 1))
cg.setLineWidth(44)
cg.setLineCap(.round)
cg.setLineJoin(.round)
let m: CGFloat = 170, len: CGFloat = 150
for (x, y, dx, dy) in [(m, m, 1.0, 1.0), (size - m, m, -1, 1), (m, size - m, 1, -1), (size - m, size - m, -1, -1)] {
    cg.move(to: CGPoint(x: x, y: y + dy * len))
    cg.addLine(to: CGPoint(x: x, y: y))
    cg.addLine(to: CGPoint(x: x + dx * len, y: y))
    cg.strokePath()
}

let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, cg.makeImage()!, nil)
precondition(CGImageDestinationFinalize(dest), "PNG write failed")
print("wrote \(out)")
