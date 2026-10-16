import Foundation
import JutsuCore
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "MediaKit")

/// Sandbox access to a file the user picked, held for as long as this object lives.
/// Resolves the file's bookmark when there is one, so access survives a relaunch; without one, or
/// when it no longer resolves, the plain URL is used and works only while this launch has access.
public final class SecurityScopedAccess: Sendable {
    /// The file to read: where the bookmark points now, which follows a moved or renamed file.
    public let url: URL
    /// A new bookmark to store in place of a stale one; `nil` when the stored one is still good.
    public let refreshedBookmark: Data?
    private let isAccessing: Bool

    public init(url: URL, bookmark: Data?) {
        var target = url
        var isStale = false
        if let bookmark {
            do {
                target = try URL(
                    resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil,
                    bookmarkDataIsStale: &isStale)
            } catch {
                logger.error("Can't resolve a bookmark: \(String(describing: error), privacy: .private)")
            }
        }
        self.url = target
        isAccessing = target.startAccessingSecurityScopedResource()
        refreshedBookmark = isStale ? (try? Self.bookmark(for: target)) : nil
    }

    deinit {
        if isAccessing { url.stopAccessingSecurityScopedResource() }
    }

    /// A read-only security-scoped bookmark. Make it while the URL is accessible: right after the
    /// picker or drop returned it, or inside started access.
    public static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil,
            relativeTo: nil)
    }

    /// Runs `body` with access to the file, then gives the access up.
    public static func withAccess<T: Sendable>(
        to url: URL, bookmark: Data?, _ body: @Sendable (URL) async throws -> T
    ) async throws -> T {
        let access = SecurityScopedAccess(url: url, bookmark: bookmark)
        let result = try await body(access.url)
        withExtendedLifetime(access) {}
        return result
    }
}

extension SourceClip {
    /// Runs `body` with access to the clip's file, then gives the access up.
    public func withAccess<T: Sendable>(_ body: @Sendable (URL) async throws -> T) async throws -> T {
        try await SecurityScopedAccess.withAccess(to: fileURL, bookmark: bookmark, body)
    }
}

extension LocalImage {
    /// Runs `body` with access to the image file, then gives the access up.
    public func withAccess<T: Sendable>(_ body: @Sendable (URL) async throws -> T) async throws -> T {
        try await SecurityScopedAccess.withAccess(to: fileURL, bookmark: bookmark, body)
    }

    /// The file as this launch reaches it: through its bookmark, which follows a moved file and is refreshed when
    /// stale; `nil` when it can't be read any more.
    public func reopened() -> LocalImage? {
        let access = SecurityScopedAccess(url: fileURL, bookmark: bookmark)
        guard FileManager.default.isReadableFile(atPath: access.url.path(percentEncoded: false)) else { return nil }
        var image = self
        image.fileURL = access.url
        image.bookmark = access.refreshedBookmark ?? bookmark
        return image
    }
}
