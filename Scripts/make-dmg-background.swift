#!/usr/bin/env swift
//
// Génère le fond du .dmg de distribution : une flèche entre l'icône de l'app et
// le raccourci vers /Applications, pour qu'ouvrir le .dmg suffise à comprendre
// qu'il faut glisser-déposer plutôt que chercher un installeur.
//
//     swift Scripts/make-dmg-background.swift
//
// Dimensions et positions doivent rester cohérentes avec les coordonnées passées
// à `create-dmg --icon` / `--app-drop-link` dans Scripts/release.sh.

import AppKit
import CoreGraphics
import CoreText
import Foundation

let width = 660
let height = 400
// Coordonnées des deux icônes dans la fenêtre Finder du .dmg (mêmes valeurs que
// celles passées à create-dmg), pour centrer la flèche entre les deux.
let appCenterX: CGFloat = 180
let appDropCenterX: CGFloat = 480
let iconCenterY: CGFloat = 400 - 190 // create-dmg compte depuis le bas de la fenêtre

guard let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("contexte CoreGraphics indisponible")
}
context.setShouldAntialias(true)
context.interpolationQuality = .high

// Fond clair et sobre, cohérent avec l'apparence par défaut du Finder.
context.setFillColor(CGColor(red: 0.965, green: 0.965, blue: 0.972, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))

// Flèche entre les deux icônes : tige + pointe, plutôt qu'un glyphe système pour
// rester indépendant de la police installée.
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

// Légende sous la flèche.
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
    "Glisse SmartMeet dans Applications",
    at: CGFloat(width) / 2, y: iconCenterY - 110,
    size: 15, weight: .medium,
    color: CGColor(red: 0.35, green: 0.35, blue: 0.38, alpha: 1)
)

guard let image = context.makeImage() else { fatalError("rendu impossible") }
let representation = NSBitmapImageRep(cgImage: image)
guard let data = representation.representation(using: .png, properties: [:]) else {
    fatalError("encodage PNG impossible")
}

let root = URL(filePath: FileManager.default.currentDirectoryPath)
let output = root.appending(path: "build/dmg-background.png")
try data.write(to: output)
print("✅ fond du .dmg généré : \(output.path)")
