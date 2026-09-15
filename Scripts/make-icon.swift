#!/usr/bin/env swift
//
// Generates the SmartMeet icon.
//
// Vector drawing rather than a binary file: the icon stays editable, diffable,
// and regenerates at every size macOS requires.
//
//     swift Scripts/make-icon.swift && iconutil -c icns build/SmartMeet.iconset
//
// Motif: a speech bubble whose interior is a sound wave that resolves into
// lines of text — capturing speech, producing a written record.

import AppKit
import CoreGraphics
import Foundation

let sizes: [(dimension: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]

/// Background gradient, in macOS's accent tones.
let backgroundColors = [
    CGColor(red: 0.45, green: 0.36, blue: 0.96, alpha: 1),
    CGColor(red: 0.30, green: 0.62, blue: 0.99, alpha: 1),
]

func drawIcon(in context: CGContext, side: CGFloat) {
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // macOS expects a margin around the template: the icon doesn't fill the square.
    let inset = side * 0.085
    let rect = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let corner = rect.width * 0.2237 // system icon squircle radius

    // Rounded background with a diagonal gradient.
    let squircle = CGPath(
        roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil
    )
    context.saveGState()
    context.addPath(squircle)
    context.clip()
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: backgroundColors as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }

    // Light sheen in the top-left corner, to avoid a flat, uniform fill.
    if let sheen = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray,
        locations: [0, 1]
    ) {
        context.drawRadialGradient(
            sheen,
            startCenter: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.maxY - rect.height * 0.2),
            startRadius: 0,
            endCenter: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.maxY - rect.height * 0.2),
            endRadius: rect.width * 0.65,
            options: []
        )
    }
    context.restoreGState()

    // White speech bubble.
    let bubbleWidth = rect.width * 0.66
    let bubbleHeight = rect.height * 0.50
    let bubble = CGRect(
        x: rect.midX - bubbleWidth / 2,
        y: rect.midY - bubbleHeight / 2 + rect.height * 0.055,
        width: bubbleWidth,
        height: bubbleHeight
    )
    let bubbleCorner = bubbleHeight * 0.30

    let bubblePath = CGMutablePath()
    bubblePath.addRoundedRect(
        in: bubble, cornerWidth: bubbleCorner, cornerHeight: bubbleCorner
    )
    // Bubble tail, at the bottom left. Wide at its base to blend into the
    // bubble's body rather than looking stuck onto it.
    let tailX = bubble.minX + bubble.width * 0.24
    let tailWidth = bubble.height * 0.34
    let tailDrop = bubble.height * 0.26
    bubblePath.move(to: CGPoint(x: tailX, y: bubble.minY + 1))
    bubblePath.addLine(to: CGPoint(x: tailX + tailWidth, y: bubble.minY + 1))
    bubblePath.addQuadCurve(
        to: CGPoint(x: tailX + tailWidth * 0.12, y: bubble.minY - tailDrop),
        control: CGPoint(x: tailX + tailWidth * 0.58, y: bubble.minY - tailDrop * 0.45)
    )
    bubblePath.closeSubpath()

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -side * 0.012),
        blur: side * 0.035,
        color: CGColor(red: 0.10, green: 0.12, blue: 0.30, alpha: 0.35)
    )
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.addPath(bubblePath)
    context.fillPath()
    context.restoreGState()

    // Bubble content: a sound wave on the left, lines of text on the right.
    // The transition from one to the other is the app's whole point.
    let contentRect = bubble.insetBy(dx: bubble.width * 0.14, dy: bubble.height * 0.24)
    let accent = CGColor(red: 0.36, green: 0.33, blue: 0.93, alpha: 1)
    context.setFillColor(accent)

    let barCount = 5
    let barWidth = contentRect.width * 0.055
    let barGap = contentRect.width * 0.055
    // Relative heights: a wave that settles down toward the right.
    let heights: [CGFloat] = [0.42, 0.86, 1.0, 0.62, 0.30]
    for index in 0..<barCount {
        let height = contentRect.height * heights[index]
        let x = contentRect.minX + CGFloat(index) * (barWidth + barGap)
        let bar = CGRect(
            x: x, y: contentRect.midY - height / 2, width: barWidth, height: height
        )
        context.addPath(CGPath(
            roundedRect: bar,
            cornerWidth: barWidth / 2,
            cornerHeight: barWidth / 2,
            transform: nil
        ))
    }
    context.fillPath()

    // Lines of text, decreasing in length like a paragraph.
    let textStartX = contentRect.minX + CGFloat(barCount) * (barWidth + barGap) + barGap * 0.4
    let textWidth = contentRect.maxX - textStartX
    let lineHeight = contentRect.height * 0.155
    let lineGap = contentRect.height * 0.155
    let lineWidths: [CGFloat] = [1.0, 0.78, 0.92]
    let totalHeight = CGFloat(lineWidths.count) * lineHeight
        + CGFloat(lineWidths.count - 1) * lineGap

    for (index, ratio) in lineWidths.enumerated() {
        let y = contentRect.midY + totalHeight / 2
            - CGFloat(index + 1) * lineHeight - CGFloat(index) * lineGap
        let line = CGRect(
            x: textStartX, y: y, width: textWidth * ratio, height: lineHeight
        )
        context.addPath(CGPath(
            roundedRect: line,
            cornerWidth: lineHeight / 2,
            cornerHeight: lineHeight / 2,
            transform: nil
        ))
    }
    context.setFillColor(accent.copy(alpha: 0.55) ?? accent)
    context.fillPath()

    // Recording dot, the icon's signature of the app's core function.
    let dotRadius = rect.width * 0.078
    let dotCenter = CGPoint(
        x: bubble.maxX - dotRadius * 0.15, y: bubble.maxY - dotRadius * 0.15
    )
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -side * 0.008),
        blur: side * 0.02,
        color: CGColor(red: 0.4, green: 0.05, blue: 0.1, alpha: 0.4)
    )
    context.setFillColor(CGColor(red: 1, green: 0.27, blue: 0.31, alpha: 1))
    context.fillEllipse(in: CGRect(
        x: dotCenter.x - dotRadius,
        y: dotCenter.y - dotRadius,
        width: dotRadius * 2,
        height: dotRadius * 2
    ))
    context.restoreGState()

    // White ring, to detach the dot from the background.
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.setLineWidth(rect.width * 0.022)
    context.strokeEllipse(in: CGRect(
        x: dotCenter.x - dotRadius,
        y: dotCenter.y - dotRadius,
        width: dotRadius * 2,
        height: dotRadius * 2
    ))
}

func renderPNG(dimension: Int, scale: Int) throws -> Data {
    let pixels = dimension * scale
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "icon", code: 1)
    }

    drawIcon(in: context, side: CGFloat(pixels))

    guard let image = context.makeImage() else { throw NSError(domain: "icon", code: 2) }
    let representation = NSBitmapImageRep(cgImage: image)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 3)
    }
    return data
}

let root = URL(filePath: FileManager.default.currentDirectoryPath)
let iconset = root.appending(path: "build/SmartMeet.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for (dimension, scale) in sizes {
    let suffix = scale == 1 ? "" : "@\(scale)x"
    let name = "icon_\(dimension)x\(dimension)\(suffix).png"
    try renderPNG(dimension: dimension, scale: scale)
        .write(to: iconset.appending(path: name))
}

print("✅ \(sizes.count) sizes generated in \(iconset.path)")
