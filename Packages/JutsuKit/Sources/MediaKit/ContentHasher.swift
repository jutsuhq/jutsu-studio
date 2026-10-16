import CryptoKit
import Foundation

/// Hex SHA-256 of file contents, read in chunks so large videos never sit in memory whole.
public enum ContentHasher {
    static let chunkSize = 1 << 20

    public static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    static func sha256Hex(of string: String) -> String {
        hex(SHA256.hash(data: Data(string.utf8)))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
