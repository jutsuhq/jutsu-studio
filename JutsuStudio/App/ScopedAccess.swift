import AVFoundation
import MediaKit

/// Runs `body` with sandbox access to the file, then gives the access up.
func withScopedAccess<T>(to url: URL, bookmark: Data?, _ body: (SecurityScopedAccess) -> T) -> T {
    let access = SecurityScopedAccess(url: url, bookmark: bookmark)
    return withExtendedLifetime(access) { body(access) }
}

/// Like the synchronous one. `body` stays on the main actor, so unlike MediaKit's `withAccess` it may
/// touch view state and return values that aren't `Sendable`.
@MainActor
func withScopedAccess<T>(
    to url: URL, bookmark: Data?, _ body: @MainActor (SecurityScopedAccess) async -> T
) async -> T {
    let access = SecurityScopedAccess(url: url, bookmark: bookmark)
    let result = await body(access)
    withExtendedLifetime(access) {}
    return result
}

/// A player item for a picked file. Sandbox access is held for as long as this value is kept,
/// because AVPlayer reads the file lazily.
@MainActor
struct ScopedPlayerItem {
    let item: AVPlayerItem
    private let access: SecurityScopedAccess

    init(url: URL, bookmark: Data?) {
        let access = SecurityScopedAccess(url: url, bookmark: bookmark)
        self.access = access
        item = AVPlayerItem(url: access.url)
    }
}
