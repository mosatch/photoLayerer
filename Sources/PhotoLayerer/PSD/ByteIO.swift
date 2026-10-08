import Foundation

enum PSDError: LocalizedError {
    case corrupt(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .corrupt(let detail): "The Photoshop file is damaged: \(detail)."
        case .unsupported(let detail): "This Photoshop file isn't supported: \(detail)."
        }
    }
}

/// Big-endian reader with bounds checking; every read past the end throws instead of trapping.
struct ByteReader {
    let data: [UInt8]
    var offset = 0

    init(_ data: Data) { self.data = [UInt8](data) }

    var remaining: Int { data.count - offset }

    mutating func bytes(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= remaining else { throw PSDError.corrupt("unexpected end of file") }
        defer { offset += count }
        return data[offset..<offset + count]
    }

    mutating func skip(_ count: Int) throws { _ = try bytes(count) }

    mutating func seek(to position: Int) throws {
        guard position >= 0, position <= data.count else { throw PSDError.corrupt("section length out of range") }
        offset = position
    }

    mutating func u8() throws -> UInt8 { try bytes(1).first! }

    mutating func u16() throws -> UInt16 {
        let b = try bytes(2)
        return UInt16(b[b.startIndex]) << 8 | UInt16(b[b.startIndex + 1])
    }

    mutating func u32() throws -> UInt32 {
        let b = try bytes(4)
        return b.reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }
    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    mutating func fourCC() throws -> String {
        String(decoding: try bytes(4), as: UTF8.self)
    }
}

struct ByteWriter {
    private(set) var data = Data()

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { data.append(UInt8(v >> 8)); data.append(UInt8(v & 0xFF)) }
    mutating func u32(_ v: UInt32) { for shift in [24, 16, 8, 0] { data.append(UInt8((v >> UInt32(shift)) & 0xFF)) } }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func fourCC(_ s: String) { data.append(contentsOf: Array(s.utf8.prefix(4))) }
    mutating func bytes<S: Sequence>(_ b: S) where S.Element == UInt8 { data.append(contentsOf: b) }
    mutating func append(_ other: Data) { data.append(other) }

    mutating func pad(toMultipleOf n: Int, from start: Int = 0) {
        while (data.count - start) % n != 0 { data.append(0) }
    }

    /// Writes a 4-byte length placeholder, runs `body`, then fills in the length of what it wrote.
    mutating func lengthPrefixed(padTo multiple: Int = 1, _ body: (inout ByteWriter) -> Void) {
        let lengthAt = data.count
        u32(0)
        let start = data.count
        body(&self)
        pad(toMultipleOf: multiple, from: start)
        let length = UInt32(data.count - start)
        for (k, shift) in [24, 16, 8, 0].enumerated() {
            data[lengthAt + k] = UInt8((length >> UInt32(shift)) & 0xFF)
        }
    }
}
