import Compression
import CoreGraphics
import Foundation
import ImageIO

/// Reads 8-bit RGB and grayscale PSDs into editable layers.
///
/// Group folders are flattened (their contents are kept, the folder markers dropped), and layer
/// masks, adjustment layers and layer styles are not interpreted. Files with no layer data, or in
/// a mode or depth we don't decode, open as a single layer from the merged composite.
enum PSDReader {
    /// Photoshop's own limit for PSD (as opposed to PSB) files.
    static let maxSide = 30_000
    /// Caps a single bitmap at about 1 GB so a hostile file can't exhaust memory.
    static let maxPixels = 250_000_000

    static func checkSize(_ width: Int, _ height: Int) throws {
        guard width >= 0, height >= 0, width <= maxSide, height <= maxSide, width * height <= maxPixels else {
            throw PSDError.unsupported("\(width) × \(height) is too large")
        }
    }

    static func read(_ data: Data) throws -> CanvasState {
        var r = ByteReader(data)
        guard try r.fourCC() == "8BPS" else { throw PSDError.corrupt("missing 8BPS signature") }
        let version = try r.u16()
        guard version == 1 else {
            // Version 2 is PSB (large document format).
            return try compositeOnly(data, reason: "PSB")
        }
        try r.skip(6)
        let channelCount = Int(try r.u16())
        let height = Int(try r.u32())
        let width = Int(try r.u32())
        let depth = try r.u16()
        let mode = try r.u16()
        guard width > 0, height > 0, channelCount > 0 else { throw PSDError.corrupt("empty canvas") }
        try checkSize(width, height)

        try r.skip(Int(try r.u32()))  // color mode data

        let resourcesLength = Int(try r.u32())
        let resourcesEnd = r.offset + resourcesLength
        var effectsResource: Data?
        while r.offset + 12 <= resourcesEnd {
            guard try r.fourCC() == "8BIM" else { break }
            let id = try r.u16()
            let nameLength = Int(try r.u8())
            try r.skip(nameLength + (nameLength + 1) % 2)  // pascal string padded to even
            let size = Int(try r.u32())
            let body = try r.bytes(size)
            if id == PSDWriter.effectsResourceID { effectsResource = Data(body) }
            if size % 2 == 1 { try r.skip(1) }
        }
        try r.seek(to: resourcesEnd)

        guard depth == 8, mode == 3 || mode == 1 else {
            return try compositeOnly(data, reason: "depth \(depth), mode \(mode)")
        }

        let layerSectionLength = Int(try r.u32())
        let layerSectionEnd = r.offset + layerSectionLength
        guard layerSectionLength > 0 else { return try compositeOnly(data, reason: "no layers") }
        let layerInfoLength = Int(try r.u32())
        guard layerInfoLength > 0 else { return try compositeOnly(data, reason: "no layer info") }
        let layerInfoEnd = r.offset + layerInfoLength
        guard layerInfoEnd <= layerSectionEnd else { throw PSDError.corrupt("layer info overruns section") }

        let layerCount = abs(Int(try r.i16()))
        var records: [LayerRecord] = []
        for _ in 0..<layerCount {
            records.append(try readRecord(&r))
        }

        var layers: [Layer] = []
        for record in records {
            var planes: [Int16: [UInt8]] = [:]
            for channel in record.channels {
                let channelEnd = r.offset + channel.length
                // Masks (-2, -3) have their own bounds; skip them rather than decode at the wrong size.
                if channel.id >= -1 && record.width > 0 && record.height > 0 {
                    planes[channel.id] = try readPlane(&r, width: record.width, height: record.height,
                                                       end: channelEnd)
                }
                try r.seek(to: channelEnd)
            }
            guard !record.isSectionMarker else { continue }
            layers.append(makeLayer(record, planes: planes, grayscale: mode == 1))
        }
        try r.seek(to: layerInfoEnd)

        if let effectsResource { applyEffects(effectsResource, to: &layers) }
        return CanvasState(width: width, height: height, layers: layers)
    }

    // MARK: - Layer records

    private struct ChannelInfo {
        let id: Int16
        let length: Int
    }

    private struct LayerRecord {
        var top = 0, left = 0, bottom = 0, right = 0
        var channels: [ChannelInfo] = []
        var blendKey = "norm"
        var opacity: UInt8 = 255
        var flags: UInt8 = 0
        var name = ""
        var isSectionMarker = false

        var width: Int { right - left }
        var height: Int { bottom - top }
    }

    private static func readRecord(_ r: inout ByteReader) throws -> LayerRecord {
        var rec = LayerRecord()
        rec.top = Int(try r.i32())
        rec.left = Int(try r.i32())
        rec.bottom = Int(try r.i32())
        rec.right = Int(try r.i32())
        try checkSize(rec.width, rec.height)
        let channelCount = Int(try r.u16())
        for _ in 0..<channelCount {
            rec.channels.append(ChannelInfo(id: try r.i16(), length: Int(try r.u32())))
        }
        guard try r.fourCC() == "8BIM" else { throw PSDError.corrupt("bad blend signature") }
        rec.blendKey = try r.fourCC()
        rec.opacity = try r.u8()
        _ = try r.u8()  // clipping
        rec.flags = try r.u8()
        _ = try r.u8()  // filler
        let extraLength = Int(try r.u32())
        let extraEnd = r.offset + extraLength

        try r.skip(Int(try r.u32()))  // layer mask data
        try r.skip(Int(try r.u32()))  // blending ranges
        let nameLength = Int(try r.u8())
        let nameBytes = try r.bytes(nameLength)
        rec.name = String(bytes: nameBytes, encoding: .macOSRoman) ?? ""
        try r.skip((4 - (nameLength + 1) % 4) % 4)

        while r.offset + 12 <= extraEnd {
            let signature = try r.fourCC()
            guard signature == "8BIM" || signature == "8B64" else { break }
            let key = try r.fourCC()
            let length = Int(try r.u32())
            let blockEnd = r.offset + length
            switch key {
            case "luni":
                let count = Int(try r.u32())
                let utf16 = try r.bytes(count * 2)
                if let unicode = String(bytes: utf16, encoding: .utf16BigEndian), !unicode.isEmpty {
                    rec.name = unicode.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                }
            case "lsct", "lsdk":
                // 1/2 = open/closed folder, 3 = end-of-group divider. Neither carries pixels we keep.
                let type = try r.u32()
                if type != 0 { rec.isSectionMarker = true }
            default:
                break
            }
            try r.seek(to: blockEnd)
        }
        try r.seek(to: extraEnd)
        return rec
    }

    // MARK: - Pixel data

    private static func readPlane(_ r: inout ByteReader, width: Int, height: Int, end: Int) throws -> [UInt8] {
        let compression = try r.u16()
        // Even fully compressed, each row costs at least a few bytes; reject before allocating.
        guard compression != 1 || height * 2 <= end - r.offset else {
            throw PSDError.corrupt("channel data is shorter than its row table")
        }
        var plane = [UInt8](repeating: 0, count: width * height)
        switch compression {
        case 0:
            let raw = try r.bytes(width * height)
            plane.replaceSubrange(0..<plane.count, with: raw)
        case 1:
            var rowLengths: [Int] = []
            rowLengths.reserveCapacity(height)
            for _ in 0..<height { rowLengths.append(Int(try r.u16())) }
            try plane.withUnsafeMutableBufferPointer { out in
                for row in 0..<height {
                    let packed = try r.bytes(rowLengths[row])
                    try packed.withUnsafeBufferPointer { src in
                        try PackBits.decode(src, into: UnsafeMutableBufferPointer(
                            rebasing: out[row * width..<(row + 1) * width]))
                    }
                }
            }
        case 2, 3:
            let compressed = try r.bytes(end - r.offset)
            plane = try inflate(Array(compressed), expected: width * height)
            if compression == 3 {
                // ZIP with prediction: each byte stores the delta from its left neighbour.
                for row in 0..<height {
                    let base = row * width
                    for x in 1..<max(1, width) { plane[base + x] &+= plane[base + x - 1] }
                }
            }
        default:
            throw PSDError.unsupported("compression type \(compression)")
        }
        return plane
    }

    private static func inflate(_ zlib: [UInt8], expected: Int) throws -> [UInt8] {
        // PSD stores a zlib stream; Apple's COMPRESSION_ZLIB wants raw deflate, so drop the 2-byte header.
        guard zlib.count > 2 else { throw PSDError.corrupt("empty ZIP channel") }
        var out = [UInt8](repeating: 0, count: expected)
        let written = zlib.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(dst.baseAddress!, expected, src.baseAddress! + 2, src.count - 2,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expected else { throw PSDError.corrupt("ZIP channel decoded to the wrong size") }
        return out
    }

    private static func makeLayer(_ record: LayerRecord, planes: [Int16: [UInt8]], grayscale: Bool) -> Layer {
        let bitmap = Bitmap(width: record.width, height: record.height)
        if record.width > 0 && record.height > 0 {
            let count = record.width * record.height
            let red = planes[0] ?? [UInt8](repeating: 0, count: count)
            let green = grayscale ? red : planes[1] ?? red
            let blue = grayscale ? red : planes[2] ?? red
            let alpha = planes[-1]
            let px = bitmap.pixels
            for i in 0..<count {
                let a = alpha?[i] ?? 255
                px[i * 4] = premultiply(red[i], a)
                px[i * 4 + 1] = premultiply(green[i], a)
                px[i * 4 + 2] = premultiply(blue[i], a)
                px[i * 4 + 3] = a
            }
            bitmap.didChange()
        } else {
            bitmap.fill(CGColor(gray: 0, alpha: 0))
        }

        var layer = Layer(name: record.name.isEmpty ? "Layer" : record.name, bitmap: bitmap,
                          x: record.left, y: record.top)
        layer.opacity = Double(record.opacity) / 255
        layer.isVisible = record.flags & 0x02 == 0
        layer.blendMode = BlendMode(rawValue: record.blendKey) ?? .normal
        return layer
    }

    private static func premultiply(_ c: UInt8, _ a: UInt8) -> UInt8 {
        UInt8((Int(c) * Int(a) + 127) / 255)
    }

    // MARK: - Fallbacks and extras

    /// Opens the merged image ImageIO decodes from the file as a single background layer.
    private static func compositeOnly(_ data: Data, reason: String) throws -> CanvasState {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw PSDError.unsupported(reason) }
        let layer = Layer(name: "Background", bitmap: Bitmap(image: image))
        return CanvasState(width: image.width, height: image.height, layers: [layer])
    }

    private static func applyEffects(_ data: Data, to layers: inout [Layer]) {
        guard let stored = try? JSONDecoder().decode(PSDWriter.StoredEffects.self, from: data),
              stored.layers.count == layers.count
        else { return }
        for (index, entry) in stored.layers.enumerated() where entry.name == layers[index].name {
            layers[index].effects = entry.effects
        }
    }
}
