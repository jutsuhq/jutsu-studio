import CryptoKit
import Foundation

/// Hex SHA-256 of file contents, read in chunks so large videos never sit in memory whole.
public enum ContentHasher {
    static let chunkSize = 1 << 20

    public static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while try readChunk(of: handle, into: { hasher.update(data: $0) }) {
            try Task.checkCancellation()
        }
        return hex(hasher.finalize())
    }

    /// Reads the next chunk into `use`; `false` at the end. Each chunk is freed before the next is read: a chunk
    /// `FileHandle` hands out is autoreleased, so a loop without a pool keeps the whole file in memory until it ends.
    static func readChunk(of handle: FileHandle, into use: (Data) -> Void) throws -> Bool {
        try autoreleasepool {
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { return false }
            use(chunk)
            return true
        }
    }

    static func sha256Hex(of string: String) -> String {
        hex(SHA256.hash(data: Data(string.utf8)))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
