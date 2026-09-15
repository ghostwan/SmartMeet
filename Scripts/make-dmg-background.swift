#!/usr/bin/env swift
//
// Generates the distribution .dmg background: an arrow between the app icon
// and the /Applications shortcut, so opening the .dmg is enough to understand
// that you need to drag-and-drop rather than look for an installer.
//
//     swift Scripts/make-dmg-background.swift
//
// Dimensions and positions must stay consistent with the coordinates passed
// to `create-dmg --icon` / `--app-drop-link` in Scripts/release.sh.

import AppKit
import CoreGraphics
import CoreText
import Foundation

let width = 660
let height = 400
// Coordinates of the two icons in the .dmg's Finder window (same values as
// those passed to create-dmg), to center the arrow between the two.
let appCenterX: CGFloat = 180
let appDropCenterX: CGFloat = 480
let iconCenterY: CGFloat = 400 - 190 // create-dmg counts from the bottom of the window

guard let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("CoreGraphics context unavailable")
}
context.setShouldAntialias(true)
context.interpolationQuality = .high

// Light, understated background, consistent with Finder's default look.
context.setFillColor(CGColor(red: 0.965, green: 0.965, blue: 0.972, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))

// Arrow between the two icons: shaft + head, rather than a system glyph, to
// stay independent of the installed font.
let arrowY = iconCenterY
let shaftStartX = appCenterX + 60
let shaftEndX = appDropCenterX - 70
let shaftThickness: CGFloat = 6

context.setFillColor(CGColor(red: 0.55, green: 0.55, blue: 0.58, alpha: 0.9))
context.fill(CGRect(
    x: shaftStartX, y: arrowY - shaftThickness / 2,
    width: shaftEndX - shaftStartX, height: shaftThickness
))

let headLength: CGFloat = 26
let headWidth: CGFloat = 22
let head = CGMutablePath()
head.move(to: CGPoint(x: shaftEndX, y: arrowY + headWidth / 2))
head.addLine(to: CGPoint(x: shaftEndX + headLength, y: arrowY))
head.addLine(to: CGPoint(x: shaftEndX, y: arrowY - headWidth / 2))
head.closeSubpath()
context.addPath(head)
context.fillPath()

// Caption below the arrow.
func drawCentered(_ text: String, at x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: CGColor) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(cgColor: color) ?? .black,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    context.textPosition = CGPoint(x: x - bounds.width / 2, y: y)
    CTLineDraw(line, context)
}

drawCentered(
    "Drag SmartMeet into Applications",
    at: CGFloat(width) / 2, y: iconCenterY - 110,
    size: 15, weight: .medium,
    color: CGColor(red: 0.35, green: 0.35, blue: 0.38, alpha: 1)
)

guard let image = context.makeImage() else { fatalError("unable to render image") }
let representation = NSBitmapImageRep(cgImage: image)
guard let data = representation.representation(using: .png, properties: [:]) else {
    fatalError("unable to encode PNG")
}

let root = URL(filePath: FileManager.default.currentDirectoryPath)
let output = root.appending(path: "build/dmg-background.png")
try data.write(to: output)
print("✅ .dmg background generated: \(output.path)")
