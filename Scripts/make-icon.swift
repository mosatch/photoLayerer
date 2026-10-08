#!/usr/bin/env swift
//
// Draws the PhotoLayerer app icon and writes Resources/PhotoLayerer.icns.
//
//   swift Scripts/make-icon.swift
//
// Generated rather than hand drawn so the shapes stay editable and reviewable here. The motif is
// three stacked layer sheets seen from above, the top one holding a small landscape photo. It
// has to read at 16 points, so the sheets are bold flat shapes and the photo detail drops away
// at small sizes.

import AppKit
import CoreGraphics
import Foundation

let root = URL(filePath: CommandLine.arguments.first.map {
    URL(filePath: $0).deletingLastPathComponent().deletingLastPathComponent().path()
} ?? FileManager.default.currentDirectoryPath)

func colour(_ hex: UInt32, _ alpha: Double = 1) -> CGColor {
    CGColor(srgbRed: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255, alpha: alpha)
}

let plateTop = colour(0x2B2F5E)
let plateBottom = colour(0x171933)
let sheetBack = colour(0x6878F2)     // the app's cornflower accent
let sheetMiddle = colour(0xF2A65A)   // warm apricot
let skyTop = colour(0x8FD3F4)
let skyBottom = colour(0xFCE9C8)
let sun = colour(0xFFC94A)
let hillFar = colour(0x7BA88E)
let hillNear = colour(0x3F7A5C)
let edge = colour(0xFFFFFF, 0.85)

/// A rhombus: a flat square sheet seen from above at an angle.
func sheet(centre: CGPoint, halfWidth: Double, halfHeight: Double) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: centre.x, y: centre.y + halfHeight))
    path.addLine(to: CGPoint(x: centre.x + halfWidth, y: centre.y))
    path.addLine(to: CGPoint(x: centre.x, y: centre.y - halfHeight))
    path.addLine(to: CGPoint(x: centre.x - halfWidth, y: centre.y))
    path.closeSubpath()
    return path
}

func draw(into context: CGContext, size: Double) {
    let unit = size / 1024
    context.setShouldAntialias(true)

    // macOS icons sit inside their canvas with a margin around the rounded square.
    let inset = 92 * unit
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let platePath = CGPath(roundedRect: plate, cornerWidth: plate.width * 0.2237,
                           cornerHeight: plate.width * 0.2237, transform: nil)
    context.saveGState()
    context.addPath(platePath)
    context.clip()
    let plateGradient = CGGradient(colorsSpace: nil, colors: [plateTop, plateBottom] as CFArray,
                                   locations: [0, 1])!
    context.drawLinearGradient(plateGradient, start: CGPoint(x: 0, y: plate.maxY),
                               end: CGPoint(x: 0, y: plate.minY), options: [])

    let halfWidth = 300 * unit
    let halfHeight = 170 * unit
    let step = 120 * unit
    let cx = size / 2
    let lineWidth = max(1, 10 * unit)

    // Back to front: the lowest sheet first.
    for (index, fill) in [sheetBack, sheetMiddle].enumerated() {
        let centre = CGPoint(x: cx, y: size / 2 - step + Double(index) * step - 30 * unit)
        context.addPath(sheet(centre: centre, halfWidth: halfWidth, halfHeight: halfHeight))
        context.setFillColor(fill)
        context.fillPath()
    }

    // Top sheet: a landscape photo clipped to the rhombus.
    let topCentre = CGPoint(x: cx, y: size / 2 + step - 30 * unit)
    let top = sheet(centre: topCentre, halfWidth: halfWidth, halfHeight: halfHeight)
    context.saveGState()
    context.addPath(top)
    context.clip()
    let bounds = top.boundingBox
    let sky = CGGradient(colorsSpace: nil, colors: [skyTop, skyBottom] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(sky, start: CGPoint(x: 0, y: bounds.maxY), end: CGPoint(x: 0, y: bounds.minY),
                               options: [])
    if size >= 32 {
        let sunRadius = 46 * unit
        context.setFillColor(sun)
        context.fillEllipse(in: CGRect(x: topCentre.x + 60 * unit - sunRadius, y: topCentre.y + 40 * unit - sunRadius,
                                       width: sunRadius * 2, height: sunRadius * 2))
    }
    func hill(_ fill: CGColor, baseY: Double, peaks: [(Double, Double)]) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: bounds.minX, y: bounds.minY))
        path.addLine(to: CGPoint(x: bounds.minX, y: baseY))
        for (x, y) in peaks { path.addLine(to: CGPoint(x: x, y: y)) }
        path.addLine(to: CGPoint(x: bounds.maxX, y: baseY))
        path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.minY))
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(fill)
        context.fillPath()
    }
    hill(hillFar, baseY: topCentre.y - 10 * unit, peaks: [
        (cx - 170 * unit, topCentre.y + 50 * unit), (cx - 40 * unit, topCentre.y - 20 * unit),
        (cx + 150 * unit, topCentre.y + 20 * unit),
    ])
    hill(hillNear, baseY: topCentre.y - 60 * unit, peaks: [
        (cx - 90 * unit, topCentre.y - 10 * unit), (cx + 40 * unit, topCentre.y - 70 * unit),
        (cx + 200 * unit, topCentre.y - 30 * unit),
    ])
    context.restoreGState()

    context.addPath(top)
    context.setStrokeColor(edge)
    context.setLineWidth(lineWidth)
    context.setLineJoin(.round)
    context.strokePath()
    context.restoreGState()
}

func render(size: Int) -> Data {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(into: context, size: Double(size))
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let iconset = root.appending(path: "build-icon/PhotoLayerer.iconset", directoryHint: .isDirectory)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The names iconutil expects.
let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for variant in variants {
    try render(size: variant.size).write(to: iconset.appending(path: "\(variant.name).png"))
}

let resources = root.appending(path: "Resources", directoryHint: .isDirectory)
let process = Process()
process.executableURL = URL(filePath: "/usr/bin/iconutil")
process.arguments = [
    "--convert", "icns",
    "--output", resources.appending(path: "PhotoLayerer.icns").path(percentEncoded: false),
    iconset.path(percentEncoded: false),
]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote Resources/PhotoLayerer.icns from \(variants.count) sizes")
