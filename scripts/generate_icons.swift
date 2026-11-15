#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: generate_icons.swift <output-dir>\n", stderr)
    exit(2)
}

let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let size: CGFloat = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()

guard let ctx = CGContext(
    data: nil,
    width: Int(size),
    height: Int(size),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("Failed to create CGContext\n", stderr)
    exit(1)
}

// CoreGraphics uses bottom-left origin; flip to top-left for cleaner math.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r / 255.0, g / 255.0, b / 255.0, a])!
}

// 1. Deep crimson/burgundy background gradient (#5C1D1B -> #782623 -> #4A1412)
let bgColors = [
    rgba(0x5C, 0x1D, 0x1B, 1.0),
    rgba(0x78, 0x26, 0x23, 1.0),
    rgba(0x4A, 0x14, 0x12, 1.0),
] as CFArray
if let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.48, 1.0]) {
    ctx.drawLinearGradient(
        bgGradient,
        start: CGPoint(x: size * 0.25, y: 0),
        end: CGPoint(x: size * 0.75, y: size),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
}

// Warm ambient radial glow pools
if let radial = CGGradient(
    colorsSpace: colorSpace,
    colors: [rgba(220, 86, 76, 0.36), rgba(220, 86, 76, 0.0)] as CFArray,
    locations: [0.0, 1.0]
) {
    ctx.drawRadialGradient(
        radial,
        startCenter: CGPoint(x: size * 0.42, y: size * 0.36),
        startRadius: 0,
        endCenter: CGPoint(x: size * 0.42, y: size * 0.36),
        endRadius: size * 0.56,
        options: []
    )
}

// 2. Layered frosted crimson-rose glass squircle plate
let pad = size * 0.125
let plateRect = CGRect(x: pad, y: pad, width: size - pad * 2, height: size - pad * 2)
let plateRadius = size * 0.21
let platePath = CGPath(roundedRect: plateRect, cornerWidth: plateRadius, cornerHeight: plateRadius, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.02), blur: size * 0.055, color: rgba(24, 4, 4, 0.55))
ctx.addPath(platePath)
ctx.setFillColor(rgba(168, 64, 58, 0.48))
ctx.fillPath()
ctx.restoreGState()

// Specular refraction sheen inside the plate
ctx.saveGState()
ctx.addPath(platePath)
ctx.clip()
if let sheen = CGGradient(
    colorsSpace: colorSpace,
    colors: [rgba(255, 224, 222, 0.26), rgba(255, 224, 222, 0.0)] as CFArray,
    locations: [0.0, 0.55]
) {
    ctx.drawLinearGradient(
        sheen,
        start: CGPoint(x: plateRect.minX, y: plateRect.minY),
        end: CGPoint(x: plateRect.maxX * 0.85, y: plateRect.midY),
        options: []
    )
}
ctx.restoreGState()

// Coral-white glowing specular rim
ctx.saveGState()
ctx.addPath(platePath)
ctx.setStrokeColor(rgba(255, 224, 222, 0.65))
ctx.setLineWidth(6.5)
ctx.strokePath()
ctx.restoreGState()

// 3. Geometric frosted-white 3D/glass-relief 'Z' monogram (single continuous path)
let zLeft = size * 0.295
let zRight = size * 0.705
let zTop = size * 0.285
let zBottom = size * 0.715
let bar = size * 0.094
let diagW = bar * 1.18

let zPath = CGMutablePath()
zPath.move(to: CGPoint(x: zLeft, y: zTop))
zPath.addLine(to: CGPoint(x: zRight, y: zTop))
zPath.addLine(to: CGPoint(x: zRight, y: zTop + bar))
zPath.addLine(to: CGPoint(x: zLeft + diagW, y: zBottom - bar))
zPath.addLine(to: CGPoint(x: zRight, y: zBottom - bar))
zPath.addLine(to: CGPoint(x: zRight, y: zBottom))
zPath.addLine(to: CGPoint(x: zLeft, y: zBottom))
zPath.addLine(to: CGPoint(x: zLeft, y: zBottom - bar))
zPath.addLine(to: CGPoint(x: zRight - diagW, y: zTop + bar))
zPath.addLine(to: CGPoint(x: zLeft, y: zTop + bar))
zPath.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.016), blur: size * 0.032, color: rgba(38, 6, 6, 0.68))
ctx.addPath(zPath)
ctx.setFillColor(rgba(255, 255, 255, 0.96))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(zPath)
ctx.clip()
if let zGrad = CGGradient(
    colorsSpace: colorSpace,
    colors: [rgba(255, 255, 255, 1.0), rgba(255, 224, 222, 0.96)] as CFArray,
    locations: [0.0, 1.0]
) {
    ctx.drawLinearGradient(
        zGrad,
        start: CGPoint(x: zLeft, y: zTop),
        end: CGPoint(x: zLeft, y: zBottom),
        options: []
    )
}
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(zPath)
ctx.setStrokeColor(rgba(255, 255, 255, 0.95))
ctx.setLineWidth(3.0)
ctx.strokePath()
ctx.restoreGState()

guard let masterImage = ctx.makeImage() else {
    fputs("Failed to capture CGImage\n", stderr)
    exit(1)
}

func writePNG(_ image: CGImage, to url: URL, targetSize: Int) throws {
    guard let scaledCtx = CGContext(
        data: nil,
        width: targetSize,
        height: targetSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        throw NSError(domain: "WQIcon", code: 1)
    }
    scaledCtx.interpolationQuality = .high
    scaledCtx.draw(image, in: CGRect(x: 0, y: 0, width: targetSize, height: targetSize))
    guard let outImage = scaledCtx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "WQIcon", code: 2)
    }
    CGImageDestinationAddImage(dest, outImage, nil)
    if !CGImageDestinationFinalize(dest) {
        throw NSError(domain: "WQIcon", code: 3)
    }
}

let outputs: [(String, Int)] = [
    ("AppIcon1024.png", 1024),
    ("AppIcon40x40@2x.png", 80),
    ("AppIcon40x40@3x.png", 120),
    ("AppIcon60x60@2x.png", 120),
    ("AppIcon60x60@3x.png", 180),
    ("AppIcon76x76@2x~ipad.png", 152),
    ("AppIcon83.5x83.5@2x~ipad.png", 167),
]

for (name, px) in outputs {
    try writePNG(masterImage, to: outDir.appendingPathComponent(name), targetSize: px)
}
