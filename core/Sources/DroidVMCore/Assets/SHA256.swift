// SPDX-License-Identifier: GPL-2.0-or-later
//
// SHA-256, and the seam that lets a platform swap it out.
//
// WHY THIS EXISTS AT ALL
//
// Guest assets are downloaded once and kept for the life of an install. Verifying by
// digest rather than by a version string is what makes a truncated or swapped download
// detectable -- a stamp saying "v12" only records what the file claims to be, and a
// wrongly-sized file with the right name is indistinguishable from the app's side.
//
// Foundation has no digest on any platform DroidVM builds for without CryptoKit, which is
// Apple-only, and this package must build and test on the host. So the algorithm lives
// here, against published test vectors, and sits behind `FileDigestProvider` so an Apple
// build can substitute CryptoKit for speed on a multi-gigabyte image without changing any
// caller.

import Foundation

/// Where a file's digest comes from.
public protocol FileDigestProvider: Sendable {
    /// Lower-case hexadecimal SHA-256 of the file's contents.
    func sha256Hex(ofFileAt url: URL) throws -> String
}

/// The portable implementation.
///
/// Correctness is established by published known-answer vectors in the test suite, not by
/// inspection. If you change anything here, the vectors are what tell you.
public struct PortableSHA256: FileDigestProvider {

    public init() {}

    /// Reads in chunks rather than mapping the whole file: a guest image is gigabytes, and
    /// the point of verifying it is undermined if verifying it needs it all resident.
    public func sha256Hex(ofFileAt url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw GuestAssetValidationError.missing(role: .systemDisk, path: url.path)
        }
        defer { try? handle.close() }

        var state = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            state.update(chunk)
        }
        return state.finalizeHex()
    }
}

/// Incremental SHA-256.
public struct SHA256 {

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
        0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
        0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
        0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
        0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private var h: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]

    /// Bytes not yet folded into a full 64-byte block.
    private var buffer: [UInt8] = []
    private var totalBytes: UInt64 = 0
    private var isFinalized = false

    public init() {
        buffer.reserveCapacity(64)
    }

    public mutating func update(_ data: Data) {
        precondition(!isFinalized, "update() after finalize()")
        totalBytes &+= UInt64(data.count)
        buffer.append(contentsOf: data)

        var offset = 0
        while buffer.count - offset >= 64 {
            compress(block: buffer, at: offset)
            offset += 64
        }
        if offset > 0 { buffer.removeFirst(offset) }
    }

    public mutating func finalize() -> [UInt8] {
        precondition(!isFinalized, "finalize() twice")
        isFinalized = true

        let bitLength = totalBytes &* 8

        // Padding: 0x80, then zeroes until the length is 56 mod 64, then the bit length as
        // a big-endian UInt64.
        var tail = buffer
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            tail.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }

        var offset = 0
        while offset < tail.count {
            compress(block: tail, at: offset)
            offset += 64
        }

        var out: [UInt8] = []
        out.reserveCapacity(32)
        for word in h {
            out.append(UInt8((word >> 24) & 0xff))
            out.append(UInt8((word >> 16) & 0xff))
            out.append(UInt8((word >> 8) & 0xff))
            out.append(UInt8(word & 0xff))
        }
        return out
    }

    public mutating func finalizeHex() -> String {
        finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: internals

    @inline(__always)
    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }

    private mutating func compress(block: [UInt8], at offset: Int) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            let j = offset + i * 4
            w[i] = (UInt32(block[j]) << 24) | (UInt32(block[j + 1]) << 16)
                 | (UInt32(block[j + 2]) << 8) | UInt32(block[j + 3])
        }
        for i in 16..<64 {
            let x = w[i - 15], y = w[i - 2]
            let s0 = SHA256.rotr(x, 7) ^ SHA256.rotr(x, 18) ^ (x >> 3)
            let s1 = SHA256.rotr(y, 17) ^ SHA256.rotr(y, 19) ^ (y >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }

        var a = h[0], b = h[1], c = h[2], d = h[3]
        var e = h[4], f = h[5], g = h[6], hh = h[7]

        for i in 0..<64 {
            let s1 = SHA256.rotr(e, 6) ^ SHA256.rotr(e, 11) ^ SHA256.rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = hh &+ s1 &+ ch &+ SHA256.k[i] &+ w[i]
            let s0 = SHA256.rotr(a, 2) ^ SHA256.rotr(a, 13) ^ SHA256.rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj

            hh = g; g = f; f = e
            e = d &+ t1
            d = c; c = b; b = a
            a = t1 &+ t2
        }

        h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
        h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
    }

    // MARK: one-shot convenience

    public static func hexDigest(_ data: Data) -> String {
        var s = SHA256()
        s.update(data)
        return s.finalizeHex()
    }

    public static func hexDigest(_ string: String) -> String {
        hexDigest(Data(string.utf8))
    }
}
