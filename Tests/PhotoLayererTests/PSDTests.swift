import CoreGraphics
import ImageIO
import XCTest
@testable import PhotoLayerer

final class PSDTests: XCTestCase {
    func testPackBitsRoundTrip() throws {
        let rows: [[UInt8]] = [
            [],
            [7],
            [1, 2, 3, 4, 5],
            [UInt8](repeating: 9, count: 300),
            (0..<400).map { UInt8($0 % 7 == 0 ? 0 : $0 % 251) },
            [1, 1, 2, 2, 2, 2, 3, 4, 4, 4],
        ]
        for row in rows {
            let packed = row.withUnsafeBufferPointer(PackBits.encode)
            var out = [UInt8](repeating: 0, count: row.count)
            try packed.withUnsafeBufferPointer { src in
                try out.withUnsafeMutableBufferPointer { try PackBits.decode(src, into: $0) }
            }
            XCTAssertEqual(out, row)
        }
    }

    func testLayeredRoundTrip() throws {
        let background = Bitmap(width: 64, height: 48)
        background.fill(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1))

        let sticker = Bitmap(width: 20, height: 10)
        sticker.context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5))
        sticker.context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        sticker.didChange()

        var top = Layer(name: "Stícker ✨", bitmap: sticker, x: 5, y: 7)
        top.opacity = 0.6
        top.blendMode = .multiply
        top.isVisible = false
        top.effects = [LayerEffect(kind: .blur)]

        let state = CanvasState(width: 64, height: 48,
                                layers: [Layer(name: "Background", bitmap: background), top])
        let data = try PSDWriter.write(state)
        // Set TEST_RUNNER_PSD_OUT to keep the file for checking with another PSD parser.
        if let path = ProcessInfo.processInfo.environment["PSD_OUT"] {
            try data.write(to: URL(fileURLWithPath: path))
        }

        // ImageIO only reads the merged image; this proves the file is well-formed end to end.
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let composite = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(composite.width, 64)
        XCTAssertEqual(composite.height, 48)

        let read = try PSDReader.read(data)
        XCTAssertEqual(read.width, 64)
        XCTAssertEqual(read.height, 48)
        XCTAssertEqual(read.layers.count, 2)
        let layer = read.layers[1]
        XCTAssertEqual(layer.name, "Stícker ✨")
        XCTAssertEqual(layer.x, 5)
        XCTAssertEqual(layer.y, 7)
        XCTAssertEqual(layer.bitmap.width, 20)
        XCTAssertEqual(layer.bitmap.height, 10)
        XCTAssertEqual(layer.opacity, 0.6, accuracy: 0.01)
        XCTAssertEqual(layer.blendMode, .multiply)
        XCTAssertFalse(layer.isVisible)
        XCTAssertEqual(layer.effects.map(\.kind), [.blur])

        // Half-transparent red survives the premultiply/unpremultiply trip.
        let px = layer.bitmap.pixels
        XCTAssertEqual(Int(px[3]), 128, accuracy: 1)
        XCTAssertEqual(Int(px[0]), 128, accuracy: 2)
        XCTAssertEqual(px[1], 0)

        let bg = read.layers[0].bitmap.pixels
        XCTAssertEqual(Int(bg[2]), Int(0.9 * 255), accuracy: 2)
    }
}

extension PSDTests {
    /// Reads a PSD written by some other tool, when TEST_RUNNER_PSD_IN points at one.
    func testExternalFileIfProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["PSD_IN"] else { throw XCTSkip("PSD_IN not set") }
        let state = try PSDReader.read(try Data(contentsOf: URL(fileURLWithPath: path)))
        print("PSD_IN \(state.width)x\(state.height)")
        for layer in state.layers {
            let px = layer.bitmap.pixels
            print("PSD_IN layer \(layer.name) frame=\(layer.frame) opacity=\(layer.opacity) rgba=\(px[0]),\(px[1]),\(px[2]),\(px[3])")
        }
    }
}

extension PSDTests {
    func testOversizedCanvasIsRejected() throws {
        let state = CanvasState.blank(width: 8, height: 8)
        var data = try PSDWriter.write(state)
        // Height is the big-endian UInt32 at byte 14; claim 100,000 rows.
        let huge = UInt32(100_000)
        for k in 0..<4 { data[14 + k] = UInt8((huge >> UInt32(24 - 8 * k)) & 0xFF) }
        XCTAssertThrowsError(try PSDReader.read(data))
    }

    func testTruncatedFileThrows() throws {
        let data = try PSDWriter.write(CanvasState.blank(width: 32, height: 32))
        for length in [0, 10, 30, data.count / 2] {
            XCTAssertThrowsError(try PSDReader.read(data.prefix(length)), "length \(length)")
        }
    }
}
