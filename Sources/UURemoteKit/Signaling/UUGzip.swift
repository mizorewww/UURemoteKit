//
//  UUGzip.swift
//  UURemoteKit
//
//  gzip (RFC 1952) unwrapped around the Compression framework's raw
//  DEFLATE, for the `gzip_sdp` a host may answer with.
//

import Compression
import Foundation

enum UUGzip {
    enum Failure: Error {
        case notGzip
        case truncated
        case tooLarge
        case corrupt
    }

    /// The content of a gzip member, at most `limit` bytes of it.
    /// `inflated` sees the size of every chunk inflated.
    static func decompress(_ data: Data, limit: Int = 4 * 1024 * 1024, inflated: (Int) -> Void = { _ in }) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { throw Failure.notGzip }
        let flags = bytes[3]
        var offset = 10
        func skip(_ count: Int) throws {
            offset += count
            guard offset <= bytes.count - 8 else { throw Failure.truncated }
        }
        func skipString() throws {
            while offset < bytes.count - 8, bytes[offset] != 0 { offset += 1 }
            try skip(1)
        }
        if flags & 0x04 != 0 { // FEXTRA
            try skip(2)
            try skip(Int(bytes[offset - 2]) | Int(bytes[offset - 1]) << 8)
        }
        if flags & 0x08 != 0 { try skipString() } // FNAME
        if flags & 0x10 != 0 { try skipString() } // FCOMMENT
        if flags & 0x02 != 0 { try skip(2) } // FHCRC

        // Pulled a chunk at a time, inflating stops within a chunk of the
        // cap. An OutputFilter cannot: its deinit finalizes the stream again
        // and inflates past an error its handler threw.
        let end = bytes.count - 8
        var next = offset
        var output = Data()
        do {
            let filter = try InputFilter<Data>(.decompress, using: .zlib) { length in
                let upTo = min(next + length, end)
                defer { next = upTo }
                return Data(bytes[next ..< upTo])
            }
            while let chunk = try filter.readData(ofLength: 64 * 1024), !chunk.isEmpty {
                inflated(chunk.count)
                output.append(chunk)
                guard output.count <= limit else { throw Failure.tooLarge }
            }
        } catch Failure.tooLarge {
            throw Failure.tooLarge
        } catch {
            throw Failure.corrupt
        }
        // The trailer's ISIZE: the content's length, modulo 2^32.
        let size = bytes[(bytes.count - 4)...].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard UInt32(truncatingIfNeeded: output.count) == size else { throw Failure.corrupt }
        return output
    }
}
