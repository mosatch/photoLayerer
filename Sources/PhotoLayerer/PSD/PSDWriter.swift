import CoreGraphics
import Foundation

/// Writes an 8-bit RGB PSD with one pixel layer per document layer (RLE compressed), plus the
/// flattened composite that Finder, Preview and apps without layer support display.
///
/// Layer effects have no exact Photoshop equivalent, so the layer pixels are written untouched
/// and the effect settings go in a plug-in image resource that PhotoLayerer reads back. Other
/// apps ignore that resource, so in them the layers appear without effects while the composite
/// still shows the finished image.
enum PSDWriter {
    /// Image resource IDs 4000–4999 are reserved for plug-ins; readers skip IDs they don't know.
    static let effectsResourceID: UInt16 = 4000

    struct StoredEffects: Codable {
        struct Entry: Codable {
            var name: String
            var effects: [LayerEffect]
        }
        var version = 1
        var layers: [Entry]
    }

    static func write(_ state: CanvasState) throws -> Data {
        var w = ByteWriter()

        // Header
        w.fourCC("8BPS")
        w.u16(1)
        w.bytes([0, 0, 0, 0, 0, 0])
        w.u16(3)  // composite channels: RGB
        w.u32(UInt32(state.height))
        w.u32(UInt32(state.width))
        w.u16(8)
        w.u16(3)  // RGB color mode

        w.u32(0)  // color mode data

        // Image resources
        let stored = StoredEffects(layers: state.layers.map { .init(name: $0.name, effects: $0.effects) })
        let effectsJSON = try JSONEncoder().encode(stored)
        w.lengthPrefixed { w in
            w.fourCC("8BIM")
            w.u16(effectsResourceID)
            w.u16(0)  // empty pascal name, padded to even
            w.u32(UInt32(effectsJSON.count))
            w.append(effectsJSON)
            w.pad(toMultipleOf: 2)
        }

        // Layer and mask information
        w.lengthPrefixed { w in
            w.lengthPrefixed(padTo: 4) { w in
                w.i16(Int16(state.layers.count))
                let channelData = state.layers.map(encodeChannels)
                for (layer, channels) in zip(state.layers, channelData) {
                    writeRecord(layer, channels: channels, into: &w)
                }
                for channels in channelData {
                    for channel in channels { w.append(channel.data) }
                }
            }
            w.u32(0)  // global layer mask info
        }

        // Merged image, flattened onto white
        guard let composite = Compositor.render(state.layers, width: state.width, height: state.height,
                                                background: CGColor(gray: 1, alpha: 1))
        else { throw PSDError.unsupported("couldn't render the composite image") }
        let flat = Bitmap(image: composite)
        let flatRGBA = Array(UnsafeBufferPointer(start: flat.pixels, count: flat.bytesPerRow * flat.height))
        w.u16(1)
        let rows = (0..<3).map { rleRows(flatRGBA, width: flat.width, height: flat.height, channel: $0) }
        for channel in rows { for row in channel { w.u16(UInt16(row.count)) } }
        for channel in rows { for row in channel { w.bytes(row) } }

        return w.data
    }

    private struct EncodedChannel {
        let id: Int16
        /// Compression marker followed by the compressed rows.
        let data: Data
    }

    /// Channel order: transparency first, then R, G, B — the order Photoshop itself writes.
    private static func encodeChannels(_ layer: Layer) -> [EncodedChannel] {
        let unpremultiplied = unpremultiply(layer.bitmap)
        return [(Int16(-1), 3), (0, 0), (1, 1), (2, 2)].map { id, component in
            var w = ByteWriter()
            w.u16(1)
            let rows = rleRows(unpremultiplied, width: layer.bitmap.width, height: layer.bitmap.height,
                               channel: component)
            for row in rows { w.u16(UInt16(row.count)) }
            for row in rows { w.bytes(row) }
            return EncodedChannel(id: id, data: w.data)
        }
    }

    private static func writeRecord(_ layer: Layer, channels: [EncodedChannel], into w: inout ByteWriter) {
        w.i32(Int32(layer.y))
        w.i32(Int32(layer.x))
        w.i32(Int32(layer.y + layer.bitmap.height))
        w.i32(Int32(layer.x + layer.bitmap.width))
        w.u16(UInt16(channels.count))
        for channel in channels {
            w.i16(channel.id)
            w.u32(UInt32(channel.data.count))
        }
        w.fourCC("8BIM")
        w.fourCC(layer.blendMode.rawValue)
        w.u8(UInt8((layer.opacity * 255).rounded()))
        w.u8(0)  // clipping: base
        w.u8(layer.isVisible ? 0 : 0x02)
        w.u8(0)

        w.lengthPrefixed { w in
            w.u32(0)  // no layer mask
            w.u32(0)  // no blending ranges
            // Legacy name: MacRoman pascal string padded to a multiple of 4; the full name is in luni.
            let legacy = Array((layer.name.data(using: .macOSRoman, allowLossyConversion: true) ?? Data()).prefix(255))
            let nameStart = w.data.count
            w.u8(UInt8(legacy.count))
            w.bytes(legacy)
            w.pad(toMultipleOf: 4, from: nameStart)

            w.fourCC("8BIM")
            w.fourCC("luni")
            w.lengthPrefixed(padTo: 4) { w in
                let utf16 = Array(layer.name.utf16)
                w.u32(UInt32(utf16.count))
                for unit in utf16 { w.u16(unit) }
            }
        }
    }

    // MARK: - Pixels

    /// Straight (non-premultiplied) RGBA copy, which is what PSD stores.
    private static func unpremultiply(_ bitmap: Bitmap) -> [UInt8] {
        let count = bitmap.width * bitmap.height
        var out = [UInt8](repeating: 0, count: count * 4)
        let px = bitmap.pixels
        for i in 0..<count {
            let a = Int(px[i * 4 + 3])
            out[i * 4 + 3] = UInt8(a)
            guard a > 0 else { continue }
            for c in 0..<3 {
                out[i * 4 + c] = UInt8(min(255, (Int(px[i * 4 + c]) * 255 + a / 2) / a))
            }
        }
        return out
    }

    private static func rleRows(_ rgba: [UInt8], width: Int, height: Int, channel: Int) -> [[UInt8]] {
        var row = [UInt8](repeating: 0, count: width)
        return (0..<height).map { y in
            let base = y * width * 4
            for x in 0..<width { row[x] = rgba[base + x * 4 + channel] }
            return row.withUnsafeBufferPointer(PackBits.encode)
        }
    }
}
