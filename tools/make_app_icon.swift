// Draw the app icon and pack it into an `.icns`.
//
//   swiftc -O tools/make_app_icon.swift -o /tmp/make_app_icon && /tmp/make_app_icon AppIcon.icns
//
// Run by scripts/bundle_app.sh. Foundation only, so bundling needs nothing the toolchain lacks.

import Foundation

typealias RGB = (UInt8, UInt8, UInt8)

/// The panel's matte black band, DesignTokens.swift `Palette.standard.well`.
let band: RGB = (0x0D, 0x0D, 0x0D)
/// Manual 2.5.2 §1.4, in track order; DesignTokens.swift `DeviceColor.track`.
let tracks: [RGB] = [
    (0x01, 0xA9, 0x86), (0xFB, 0x5C, 0x26), (0xFA, 0xCC, 0x00), (0xE0, 0x00, 0x2E),
]

/// Steps held by each track, in track order -- the device's 64 / 32 / 48 / 32 pattern lengths.
let steps = [4, 2, 3, 2]
let columns = 4

// Proportions of the 1024 grid. The body is Apple's rounded square, inset for the shadow the
// system draws around it; everything else is a fraction of the square it sits in.
let bodyInset = 100.0
let bodyRadius = 185.4
let contentInset = 112.0
let rowPitch = 5.26  // four rows and three gaps, in units of one row's height
let gapRatio = 0.42
let stepGapRatio = 0.24
let stepRadiusRatio = 0.28

/// Below this the steps are drawn merged: a 4 px cell either aliases or closes its own gaps.
let segmentedFrom = 64

/// `iconutil` reads these names and nothing else.
let ladder: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

/// A square RGBA bitmap, straight alpha, that draws rounded rectangles and emits a PNG.
struct Canvas {
    let size: Int
    var pixels: [UInt8]

    init(size: Int) {
        self.size = size
        pixels = [UInt8](repeating: 0, count: size * size * 4)
    }

    mutating func roundRect(
        _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ radius: Double, _ rgb: RGB
    ) {
        let cx = (x0 + x1) / 2
        let cy = (y0 + y1) / 2
        let halfW = (x1 - x0) / 2
        let halfH = (y1 - y0) / 2
        let r = min(radius, halfW, halfH)
        for y in max(0, Int(y0) - 1)..<min(size, Int(y1) + 2) {
            let qy = max(abs(Double(y) + 0.5 - cy) - (halfH - r), 0.0)
            for x in max(0, Int(x0) - 1)..<min(size, Int(x1) + 2) {
                let qx = max(abs(Double(x) + 0.5 - cx) - (halfW - r), 0.0)
                let coverage = min(max(0.5 - ((qx * qx + qy * qy).squareRoot() - r), 0.0), 1.0)
                if coverage > 0 {
                    blend(x, y, rgb, coverage)
                }
            }
        }
    }

    // Half-to-even on purpose: schoolbook rounding moves edge pixels off the shipped icon.
    private mutating func blend(_ x: Int, _ y: Int, _ rgb: RGB, _ alpha: Double) {
        let i = (y * size + x) * 4
        let dstAlpha = Double(pixels[i + 3]) / 255
        let outAlpha = alpha + dstAlpha * (1 - alpha)
        for (channel, value) in [rgb.0, rgb.1, rgb.2].enumerated() {
            let src = Double(value) * alpha
            let dst = Double(pixels[i + channel]) * dstAlpha * (1 - alpha)
            pixels[i + channel] = UInt8(((src + dst) / outAlpha).rounded(.toNearestOrEven))
        }
        pixels[i + 3] = UInt8((outAlpha * 255).rounded(.toNearestOrEven))
    }

    func png() throws -> Data {
        let stride = size * 4
        var raw = Data(capacity: size * (stride + 1))
        for y in 0..<size {
            raw.append(0)  // filter type: none
            raw.append(contentsOf: pixels[(y * stride)..<((y + 1) * stride)])
        }
        var header = Data()
        header.append(bigEndian: UInt32(size))
        header.append(bigEndian: UInt32(size))
        header.append(contentsOf: [8, 6, 0, 0, 0])

        var out = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        out.append(chunk("IHDR", header))
        out.append(chunk("IDAT", try zlibStream(raw)))
        out.append(chunk("IEND", Data()))
        return out
    }
}

extension Data {
    mutating func append(bigEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

func chunk(_ tag: String, _ data: Data) -> Data {
    let body = Data(tag.utf8) + data
    var out = Data()
    out.append(bigEndian: UInt32(data.count))
    out.append(body)
    out.append(bigEndian: crc32(body))
    return out
}

let crcTable: [UInt32] = (0..<256).map { n in
    (0..<8).reduce(UInt32(n)) { c, _ in c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
}

func crc32(_ data: Data) -> UInt32 {
    ~data.reduce(~UInt32(0)) { crcTable[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
}

/// Foundation's `.zlib` is raw DEFLATE; PNG wants the RFC 1950 header and Adler-32 around it.
func zlibStream(_ data: Data) throws -> Data {
    let deflated = try (data as NSData).compressed(using: .zlib) as Data
    var a: UInt32 = 1
    var b: UInt32 = 0
    for byte in data {
        a = (a + UInt32(byte)) % 65521
        b = (b + a) % 65521
    }
    var out = Data([0x78, 0x9C])
    out.append(deflated)
    out.append(bigEndian: b << 16 | a)
    return out
}

/// The pattern map in miniature: four rows of steps in the four track colours.
func render(_ size: Int) throws -> Data {
    let scale = Double(size) / 1024
    var canvas = Canvas(size: size)
    let body0 = bodyInset * scale
    let body1 = (1024 - bodyInset) * scale
    canvas.roundRect(body0, body0, body1, body1, bodyRadius * scale, band)

    let left = body0 + contentInset * scale
    let right = body1 - contentInset * scale
    let (top, bottom) = (left, right)
    let rowHeight = (bottom - top) / rowPitch
    let rowGap = rowHeight * gapRatio
    let stepGap = rowHeight * stepGapRatio
    let stepRadius = rowHeight * stepRadiusRatio
    let stepWidth = ((right - left) - Double(columns - 1) * stepGap) / Double(columns)

    for (track, count) in steps.enumerated() {
        let y0 = top + Double(track) * (rowHeight + rowGap)
        let y1 = y0 + rowHeight
        if size < segmentedFrom {
            let width = Double(count) * stepWidth + Double(count - 1) * stepGap
            canvas.roundRect(left, y0, left + width, y1, stepRadius, tracks[track])
            continue
        }
        for step in 0..<count {
            let x0 = left + Double(step) * (stepWidth + stepGap)
            canvas.roundRect(x0, y0, x0 + stepWidth, y1, stepRadius, tracks[track])
        }
    }
    return try canvas.png()
}

func writeICNS(to destination: URL) throws {
    let files = FileManager.default
    let scratch = files.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? files.removeItem(at: scratch) }
    let iconset = scratch.appending(path: "AppIcon.iconset")
    try files.createDirectory(at: iconset, withIntermediateDirectories: true)

    var drawn: [Int: Data] = [:]
    for (name, size) in ladder {
        if drawn[size] == nil {
            drawn[size] = try render(size)
        }
        try drawn[size]!.write(to: iconset.appending(path: name))
    }
    try files.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

    let iconutil = Process()
    iconutil.executableURL = URL(filePath: "/usr/bin/iconutil")
    iconutil.arguments = ["--convert", "icns", "--output", destination.path, iconset.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        throw CocoaError(.fileWriteUnknown)
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make_app_icon <output.icns>\n".utf8))
    exit(2)
}
try writeICNS(to: URL(filePath: arguments[1]))
