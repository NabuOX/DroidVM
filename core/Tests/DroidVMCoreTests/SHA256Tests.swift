// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import DroidVMCore

/// SHA-256, against published known-answer vectors.
///
/// This is checked by vectors rather than by inspection, because a digest implementation
/// that is *nearly* right is worse than none: it would reject good downloads
/// intermittently and look like a network problem. The vectors include the empty input,
/// the classic short strings, and inputs that straddle the 55/56/64-byte padding
/// boundaries, which is where padding bugs live.
final class SHA256Tests: XCTestCase {

    func testKnownAnswerVectors() {
        let vectors: [(String, String)] = [
            ("",
             "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc",
             "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
             "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
            ("The quick brown fox jumps over the lazy dog",
             "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"),
        ]
        for (input, expected) in vectors {
            XCTAssertEqual(SHA256.hexDigest(input), expected,
                           "SHA-256 of \(input.count) bytes")
        }
    }

    /// A million 'a' characters: the standard long vector, and the one that catches a
    /// mid-stream state bug that short inputs cannot.
    func testOneMillionAVector() {
        let data = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)
        XCTAssertEqual(SHA256.hexDigest(data),
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    /// Incremental updates must equal the one-shot digest for every size around a block
    /// boundary, and for chunk sizes that do not divide the block.
    func testIncrementalMatchesOneShotAcrossBlockBoundaries() {
        for size in [0, 1, 54, 55, 56, 57, 63, 64, 65, 119, 120, 127, 128, 129, 1000] {
            let data = Data((0..<size).map { UInt8($0 % 251) })
            let oneShot = SHA256.hexDigest(data)

            var incremental = SHA256()
            var offset = 0
            var chunk = 7                     // deliberately not a divisor of 64
            while offset < data.count {
                let end = min(offset + chunk, data.count)
                incremental.update(data.subdata(in: offset..<end))
                offset = end
                chunk = chunk == 7 ? 13 : 7
            }
            XCTAssertEqual(incremental.finalizeHex(), oneShot,
                           "incremental digest differs at size \(size)")
        }
    }

    func testFinalizeProducesThirtyTwoBytes() {
        var s = SHA256()
        s.update(Data("abc".utf8))
        XCTAssertEqual(s.finalize().count, 32)
    }

    /// The provider reads a real file in chunks, so a file larger than the chunk size must
    /// match a digest computed over the whole thing.
    func testFileProviderStreamsAndMatches() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("droidvm-sha-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }

        // Larger than the provider's 1 MiB read chunk, so a chunking bug cannot hide.
        let data = Data((0..<(2_500_000)).map { UInt8($0 % 256) })
        try data.write(to: url)

        XCTAssertEqual(try PortableSHA256().sha256Hex(ofFileAt: url),
                       SHA256.hexDigest(data))
    }
}
