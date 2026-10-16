import Foundation
import JutsuCore
import Testing

@testable import Presentation

enum Fixture {
    static func tokens(_ access: String = "access-1", email: String? = nil, name: String? = nil) -> OAuthTokens {
        OAuthTokens(
            accessToken: access, refreshToken: "refresh", expiresAt: Date(timeIntervalSince1970: 20_000),
            scope: "openid email offline_access", clientID: "client", email: email, name: name)
    }

    static let signInPage = URL(string: "https://example.com/oauth/authorize?state=1")!
}

final class FakeVault: CredentialVault, @unchecked Sendable {
    // Safe: `data` is only touched under `lock`.
    private let lock = NSLock()
    private var data: Data?
    var failsDelete = false
    /// Reads throw, like a locked Keychain.
    var failsLoad = false

    init(_ credential: Credential? = nil) {
        data = credential.flatMap { try? JSONEncoder().encode($0) }
    }

    func saveData(_ data: Data) throws {
        locked { self.data = data }
    }

    func loadData() throws -> Data? {
        if failsLoad { throw CocoaError(.fileReadNoPermission) }
        return locked { data }
    }

    func delete() throws {
        if failsDelete { throw CocoaError(.fileWriteNoPermission) }
        locked { data = nil }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var credential: Credential? { try? loadCredential() }
}

final class FakeMetadataStore: ConnectionMetadataStore {
    var stored: ConnectionMetadata?

    init(_ stored: ConnectionMetadata? = nil) {
        self.stored = stored
    }

    func load() -> ConnectionMetadata? { stored }
    func save(_ metadata: ConnectionMetadata) { stored = metadata }
    func clear() { stored = nil }
}

struct FakeServices: ConnectionServices {
    var validate: @Sendable (String, String) async throws -> Bool = { _, _ in true }
    var browser: @Sendable () async throws -> OAuthTokens = { Fixture.tokens() }
    /// The `previous` tokens of every sign-in, in order.
    let previous = Box<[OAuthTokens?]>([])
    let revoked = Box<[OAuthTokens]>([])

    func validateAPIKey(id: String, secret: String) async throws -> Bool {
        try await validate(id, secret)
    }

    func signInWithBrowser(
        reusing previous: OAuthTokens?, show: @escaping @Sendable (URL) async -> Void
    ) async throws -> OAuthTokens {
        self.previous.update { $0.append(previous) }
        await show(Fixture.signInPage)
        return try await browser()
    }

    func revoke(_ tokens: OAuthTokens) async {
        revoked.update { $0.append(tokens) }
    }
}

/// A provider that only answers `balance()`; everything else is refused.
struct BalanceProvider: GenerationProvider {
    var kind = ProviderKind.account
    var owner: String? = "user_1"
    var answer: @Sendable () async throws -> Balance?

    func capabilities() throws -> Capabilities { throw ProviderError.modelUnavailable }
    func presets() throws -> [StylePreset] { [] }
    func estimate(_ spec: JobSpec) throws -> Cost { throw ProviderError.modelUnavailable }
    func upload(_ file: PreparedFile) throws -> RemoteAsset { throw ProviderError.modelUnavailable }
    func submit(_ spec: JobSpec, inputs: RemoteInputs, idempotencyKey: UUID) throws -> RemoteJob {
        throw ProviderError.modelUnavailable
    }
    func submitIsIdempotent(_ spec: JobSpec) -> Bool { true }
    func status(_ job: RemoteJob) throws -> RemoteStatus { throw ProviderError.modelUnavailable }
    func cancel(_ job: RemoteJob) throws { throw ProviderError.modelUnavailable }
    func balance() async throws -> Balance? { try await answer() }
}

/// A value shared with `@Sendable` fakes.
final class Box<Value: Sendable>: @unchecked Sendable {
    // Safe: `stored` is only touched under `lock`.
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }

    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

/// Waits until its task is cancelled, then records that it was and throws `CancellationError`.
/// Records an issue instead after `timeout`.
func waitForCancellation(
    _ cancelled: Box<Bool>, timeout: Duration = .seconds(10), sourceLocation: SourceLocation = #_sourceLocation
) async throws -> OAuthTokens {
    let deadline = ContinuousClock.now + timeout
    while !Task.isCancelled {
        guard ContinuousClock.now < deadline else {
            Issue.record("Task was not cancelled within \(timeout)", sourceLocation: sourceLocation)
            throw CancellationError()
        }
        await Task.yield()
    }
    cancelled.update { $0 = true }
    throw CancellationError()
}
