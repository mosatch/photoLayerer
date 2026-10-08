import Foundation

/// The PackBits run-length scheme PSD uses for compression type 1.
enum PackBits {
    static func encode(_ row: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(row.count + row.count / 128 + 1)
        var i = 0
        let n = row.count
        while i < n {
            // Length of the run of identical bytes starting at i.
            var run = 1
            while i + run < n && run < 128 && row[i + run] == row[i] { run += 1 }
            if run >= 3 {
                out.append(UInt8(bitPattern: Int8(1 - run)))
                out.append(row[i])
                i += run
                continue
            }
            // Literal span: stop before the next run of three or at 128 bytes.
            let start = i
            while i < n && i - start < 128 {
                if i + 2 < n && row[i] == row[i + 1] && row[i] == row[i + 2] { break }
                i += 1
            }
            out.append(UInt8(i - start - 1))
            out.append(contentsOf: row[start..<i])
        }
        return out
    }

    /// Decodes into `out`, which must already hold exactly the expected number of bytes.
    static func decode(_ src: UnsafeBufferPointer<UInt8>, into out: UnsafeMutableBufferPointer<UInt8>) throws {
        var i = 0
        var o = 0
        while o < out.count {
            guard i < src.count else { throw PSDError.corrupt("RLE data ended early") }
            let header = Int(Int8(bitPattern: src[i]))
            i += 1
            if header >= 0 {
                let count = header + 1
                guard i + count <= src.count, o + count <= out.count else {
                    throw PSDError.corrupt("RLE literal overruns row")
                }
                for k in 0..<count { out[o + k] = src[i + k] }
                i += count
                o += count
            } else if header != -128 {
                let count = 1 - header
                guard i < src.count, o + count <= out.count else {
                    throw PSDError.corrupt("RLE run overruns row")
                }
                let byte = src[i]
                i += 1
                for k in 0..<count { out[o + k] = byte }
                o += count
            }
        }
    }
}
