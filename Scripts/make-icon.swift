#!/usr/bin/env swift
//
// Regenerates Resources/tetmux.icns from the icon render at the repo root.
//
// This is a build-time-free step on purpose: it is run by hand when the artwork changes, and the
// resulting .icns is committed. `Scripts/package-dmg.sh` only copies it. Compiling the
// `tetmux.icon` Icon Composer document instead would need `actool` from a full Xcode, which is
// exactly what CI does not have — the same reason the .dmg is single-architecture.
//
// The source is a marketing render: the icon sitting on a page background, with a drop shadow and a
// stray sparkle in the corner. So this finds the squircle, cuts it out, throws the page away, and
// re-lays it out on the 1024 canvas at the 824 pt Apple uses, leaving the surround transparent.
//
// Usage: swift Scripts/make-icon.swift [source.png] [output.icns]

import AppKit

let arguments = CommandLine.arguments
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let sourceURL = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : repoRoot.appendingPathComponent("Design/tetmux.png").path)
let outputURL = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : repoRoot.appendingPathComponent("Sources/tetmuxUI/Resources/tetmux.icns").path)

// MARK: - Load

guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("cannot read \(sourceURL.path)\n".utf8))
    exit(1)
}

let width = image.width, height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
guard let readContext = CGContext(
    data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }
readContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

/// Luminance at a top-left-origin coordinate. The bitmap is bottom-up, hence the flip.
func luminance(x: Int, y: Int) -> Double {
    let i = ((height - 1 - y) * width + x) * 4
    return (Double(pixels[i]) * 0.299 + Double(pixels[i + 1]) * 0.587 + Double(pixels[i + 2]) * 0.114)
}

// MARK: - Find the squircle
//
// Harder than it sounds, because the icon's white body and the page behind it sit within a luma point
// or two of each other (~231 either side). Thresholding on brightness finds nothing at all; so does
// looking for a sustained level shift, because there is no shift to find.
//
// What does mark the boundary is the drop shadow: a narrow trough a good 15-30 luma below the page,
// immediately outside the edge, with the body recovering to just *above* the page level inside it. So
// the scan looks for that trough and then takes the edge to be where the profile climbs back through
// the page level. Averaging a band of scanlines first is what makes this survive the render's speckle.

/// Mean luminance of a horizontal band, as one profile.
func rowProfile(centre y: Int, band: Int) -> [Double] {
    (0..<width).map { x in
        (max(0, y - band)...min(height - 1, y + band)).reduce(0.0) { $0 + luminance(x: x, y: $1) }
            / Double(min(height - 1, y + band) - max(0, y - band) + 1)
    }
}

/// Mean luminance of a vertical band, as one profile.
func columnProfile(centre x: Int, band: Int) -> [Double] {
    (0..<height).map { y in
        (max(0, x - band)...min(width - 1, x + band)).reduce(0.0) { $0 + luminance(x: $1, y: y) }
            / Double(min(width - 1, x + band) - max(0, x - band) + 1)
    }
}

/// Scans inward from `from` toward `to` for the shadow trough, and returns where the profile climbs
/// back through the page level on the inside of it — that crossing is the edge of the body.
func edge(in profile: [Double], from: Int, to: Int, trough: Double = 10) -> Int? {
    let step = to > from ? 1 : -1
    // The page level, sampled just inside the margin rather than at the very edge.
    let base = (0..<24).reduce(0.0) { $0 + profile[from + $1 * step] } / 24
    var i = from
    while i != to {
        if profile[i] < base - trough {
            // In the trough. Walk on until the body brings the level back up.
            var j = i
            while j != to, profile[j] < base { j += step }
            return j == to ? nil : j
        }
        i += step
    }
    return nil
}

// Bands taken through the middle of the shape, where its edges are straight and furthest apart.
let horizontal = rowProfile(centre: height / 2, band: 40)
let vertical = columnProfile(centre: width / 2, band: 40)

// Only three edges are measured. Below the icon the page carries a gradient that is brighter than the
// body's own bottom rim, so the trough the other three rely on is not there to find; the shape is
// square, so the width settles it anyway.
guard let left = edge(in: horizontal, from: 40, to: width / 2),
      let right = edge(in: horizontal, from: width - 41, to: width / 2),
      let top = edge(in: vertical, from: 40, to: height / 2) else {
    FileHandle.standardError.write(Data("could not locate the icon in \(sourceURL.lastPathComponent)\n".utf8))
    exit(1)
}

let side = right - left
let cropX = left
let cropY = top
print("icon edges: left \(left), right \(right), top \(top) — cropping \(side)x\(side) at (\(cropX), \(cropY))")

guard let cropped = image.cropping(to: CGRect(x: cropX, y: cropY, width: side, height: side)) else { exit(1) }

// MARK: - Mask
//
// The corners of that crop are still page background, and the drop shadow bleeds along the edges.
// Clipping to a superellipse — |x|^n + |y|^n = 1, n ≈ 5, which is the shape Apple's icons use —
// removes both, at the cost of the baked shadow. That is the right trade: macOS composites its own
// treatment behind the icon, and a grey square in the Dock is far more visible than a missing shadow.

/// A superellipse inscribed in `rect`.
func superellipse(in rect: CGRect, exponent n: Double = 5.0, samples: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    for i in 0...samples {
        let t = Double(i) / Double(samples) * 2 * .pi
        let c = cos(t), s = sin(t)
        // Signed root, so the curve traces all four quadrants.
        let x = pow(abs(c), 2 / n) * (c < 0 ? -1 : 1) * a
        let y = pow(abs(s), 2 / n) * (s < 0 ? -1 : 1) * b
        let point = CGPoint(x: cx + x, y: cy + y)
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

let canvas = 1024
// 824/1024 is the macOS convention: the shape does not run to the edge of its canvas.
let bodySide = 824.0
let inset = 2.0  // swallows the last of the page fringe at the boundary

guard let outContext = CGContext(
    data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }
outContext.interpolationQuality = .high

let body = CGRect(
    x: (Double(canvas) - bodySide) / 2, y: (Double(canvas) - bodySide) / 2,
    width: bodySide, height: bodySide
)
outContext.saveGState()
outContext.addPath(superellipse(in: body.insetBy(dx: inset, dy: inset)))
outContext.clip()
outContext.draw(cropped, in: body)
outContext.restoreGState()

guard let final = outContext.makeImage() else { exit(1) }

// MARK: - Write the iconset

let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("tetmux-\(UUID().uuidString).iconset")
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

// iconutil requires exactly these names; anything missing and the .icns silently lacks that size.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let scaled = CGContext(
        data: nil, width: variant.pixels, height: variant.pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { exit(1) }
    scaled.interpolationQuality = .high
    scaled.draw(final, in: CGRect(x: 0, y: 0, width: variant.pixels, height: variant.pixels))

    guard let out = scaled.makeImage() else { exit(1) }
    let url = iconset.appendingPathComponent("\(variant.name).png")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { exit(1) }
    CGImageDestinationAddImage(dest, out, nil)
    CGImageDestinationFinalize(dest)
}

try? FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true
)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputURL.path]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }

print("wrote \(outputURL.path)")
