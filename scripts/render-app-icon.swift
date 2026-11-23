// Renders the App Store icon (1024x1024, opaque) from the Aria mark in the
// desktop softphone's public/icon.svg: the indigo-to-purple gradient and the
// waveform bars, full bleed. iOS applies its own corner mask, so the artwork
// must fill the square and carry no alpha channel (ITMS-90717).
//
//   swift scripts/render-app-icon.swift AriaSoftphone/Resources/Assets.xcassets/AppIcon.appiconset/icon_1024.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon_1024.png"

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
// noneSkipLast: no alpha channel in the written PNG.
let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
)!
// SVG coordinates: origin top-left.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

let background = CGGradient(
    colorsSpace: space,
    colors: [rgb(0x6366f1), rgb(0x8b5cf6), rgb(0xa855f7)] as CFArray,
    locations: [0, 0.5, 1]
)!
ctx.drawLinearGradient(background, start: .zero, end: CGPoint(x: size, y: size), options: [])

// The SVG's 448-unit rounded square becomes the whole canvas.
// The bars are drawn a little smaller so they sit inside the area the
// system's corner mask never touches.
let scale = CGFloat(size) / 448 * 0.88
let center = CGFloat(size) / 2

// Soft highlight fading out down the upper half, as in the SVG.
let highlight = CGGradient(
    colorsSpace: space,
    colors: [rgb(0xffffff, 0.14), rgb(0xffffff, 0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(highlight, start: .zero, end: CGPoint(x: 0, y: center * 1.1), options: [])

// (x, y, width, height, opacity) of each bar, relative to the centre.
let bars: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
    (-16, -120, 32, 240, 1.0),
    (-72, -80, 28, 160, 0.9), (44, -80, 28, 160, 0.9),
    (-120, -48, 24, 96, 0.75), (96, -48, 24, 96, 0.75),
    (-160, -28, 20, 56, 0.55), (140, -28, 20, 56, 0.55),
]
for (x, y, w, h, opacity) in bars {
    let rect = CGRect(x: center + x * scale, y: center + y * scale, width: w * scale, height: h * scale)
    let path = CGPath(roundedRect: rect, cornerWidth: rect.width / 2, cornerHeight: rect.width / 2, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let bar = CGGradient(
        colorsSpace: space,
        colors: [rgb(0xffffff, 0.92 * opacity), rgb(0xe0e7ff, 0.95 * opacity)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(bar, start: CGPoint(x: rect.minX, y: 0), end: CGPoint(x: rect.maxX, y: 0), options: [])
    ctx.restoreGState()
}

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: out) as CFURL
let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(out)") }
print("wrote \(out) (\(size)x\(size), opaque)")
