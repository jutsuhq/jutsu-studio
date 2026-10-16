import Foundation
import JutsuCore
import JutsuTestSupport
import Testing

@testable import Presentation

@MainActor
@Suite(.timeLimit(.minutes(1))) struct ConnectionStoreTests {
    let vault: FakeVault
    let metadata: FakeMetadataStore

    init() {
        vault = FakeVault()
        metadata = FakeMetadataStore()
    }

    func store(
        _ services: FakeServices = FakeServices(), vault: FakeVault? = nil, metadata: FakeMetadataStore? = nil
    )
        -> (ConnectionStore, Recorder)
    {
        let store = ConnectionStore(
            vault: vault ?? self.vault, metadata: metadata ?? self.metadata, services: services)
        let recorder = Recorder()
        store.onCredentialChange = { recorder.credentials.append($0) }
        return (store, recorder)
    }

    // MARK: Restore

    @Test func freshInstallStartsDisconnected() async {
        let (store, recorder) = store()
        #expect(store.state == .none)
        await store.activate()
        #expect(recorder.credentials == [nil])
    }

    @Test func persistedAPIKeyIsRestoredAndReportedOnActivate() async {
        let vault = FakeVault(.apiKey(id: "kid", secret: "s"))
        let metadata = FakeMetadataStore(ConnectionMetadata(kind: .apiKey, displayName: "kid", plan: nil))
        let (store, recorder) = store(vault: vault, metadata: metadata)
        #expect(store.state == .apiKey(keyID: "kid"))
        await store.activate()
        #expect(recorder.credentials == [.apiKey(id: "kid", secret: "s")])
    }

    @Test func persistedAccountIsRestored() {
        let vault = FakeVault(.oauth(Fixture.tokens()))
        let metadata = FakeMetadataStore(ConnectionMetadata(kind: .account, displayName: "me@example.com", plan: "Pro"))
        let (store, _) = store(vault: vault, metadata: metadata)
        #expect(store.state == .account(AccountInfo(email: "me@example.com", plan: "Pro")))
    }

    @Test func metadataWithoutCredentialIsDropped() {
        let metadata = FakeMetadataStore(ConnectionMetadata(kind: .apiKey, displayName: "kid", plan: nil))
        let (store, _) = store(metadata: metadata)
        #expect(store.state == .none)
        #expect(metadata.stored == nil)
    }

    @Test func credentialOfAnotherKindIsNotRestored() {
        let vault = FakeVault(.oauth(Fixture.tokens()))
        let metadata = FakeMetadataStore(ConnectionMetadata(kind: .apiKey, displayName: "kid", plan: nil))
        let (store, _) = store(vault: vault, metadata: metadata)
        #expect(store.state == .none)
    }

    // MARK: API key

    @Test func validKeyIsTrimmedSavedAndReported() async {
        let checked = Recorder()
        let services = FakeServices(validate: { id, secret in
            await MainActor.run { checked.keys.append("\(id):\(secret)") }
            return true
        })
        let (store, recorder) = store(services)
        let form = APIKeyForm(keyID: "  kid\t", secret: "\nsecret\n")
        #expect(form.isComplete)
        await store.connectAPIKey(form)
        #expect(checked.keys == ["kid:secret"])
        #expect(store.state == .apiKey(keyID: "kid"))
        #expect(store.activity == .idle)
        #expect(store.alert == nil)
        #expect(vault.credential == .apiKey(id: "kid", secret: "secret"))
        #expect(metadata.stored == ConnectionMetadata(kind: .apiKey, displayName: "kid", plan: nil))
        #expect(recorder.credentials == [.apiKey(id: "kid", secret: "secret")])
    }

    @Test func refusedKeyShowsKeyIsInvalidAndSavesNothing() async {
        let (store, recorder) = store(FakeServices(validate: { _, _ in false }))
        await store.connectAPIKey(APIKeyForm(keyID: "kid", secret: "bad"))
        #expect(store.state == .none)
        #expect(store.alert == .invalidKey)
        #expect(vault.credential == nil)
        #expect(metadata.stored == nil)
        #expect(recorder.credentials.isEmpty)
    }

    @Test func networkFailureWhileValidatingSaysSoAndSavesNothing() async {
        let (store, _) = store(FakeServices(validate: { _, _ in throw ProviderError.network }))
        await store.connectAPIKey(APIKeyForm(keyID: "kid", secret: "s"))
        #expect(store.state == .none)
        #expect(store.alert?.title == "Can't reach Higgsfield")
        #expect(store.activity == .idle)
        #expect(vault.credential == nil)
    }

    @Test func incompleteFormIsNotSent() async {
        let (store, _) = store(
            FakeServices(validate: { _, _ in
                Issue.record("validated"); return true
            }))
        await store.connectAPIKey(APIKeyForm(keyID: "kid", secret: "   "))
        #expect(store.alert == .incompleteKey)
        #expect(store.state == .none)
    }

    // MARK: Account

    @Test func browserSignInConnectsTheAccount() async {
        let (store, recorder) = store()
        await store.startSignIn().value
        #expect(store.state == .account(AccountInfo()))
        #expect(store.activity == .idle)
        #expect(vault.credential == .oauth(Fixture.tokens()))
        #expect(metadata.stored?.kind == .account)
        #expect(recorder.credentials == [.oauth(Fixture.tokens())])
    }

    @Test func closingTheBrowserSheetIsSilent() async {
        let (store, _) = store(FakeServices(browser: { throw CancellationError() }))
        await store.startSignIn().value
        #expect(store.state == .none)
        #expect(store.alert == nil)
        #expect(store.activity == .idle)
    }

    @Test func deniedAccessShowsAMessage() async {
        let (store, _) = store(FakeServices(browser: { throw SignInError.denied }))
        await store.startSignIn().value
        #expect(store.state == .none)
        #expect(store.alert?.title == "Access was denied")
    }

    @Test func canceledSignInIgnoresALateResult() async {
        let gate = Gate<OAuthTokens>()
        let (store, recorder) = store(FakeServices(browser: { try await gate.wait() }))
        let task = store.startSignIn()
        #expect(store.activity == .signingIn(nil))
        await eventually { await gate.isWaiting }
        store.cancelSignIn()
        #expect(store.activity == .idle)
        await gate.open(.success(Fixture.tokens()))
        await task.value
        #expect(store.state == .none)
        #expect(vault.credential == nil)
        #expect(recorder.credentials.isEmpty)
    }

    @Test func theSignInPageIsShownWhileTheBrowserIsOpen() async {
        let gate = Gate<OAuthTokens>()
        let (store, _) = store(FakeServices(browser: { try await gate.wait() }))
        let task = store.startSignIn()
        #expect(store.activity == .signingIn(nil))
        await eventually { store.activity == .signingIn(Fixture.signInPage) }
        await gate.open(.success(Fixture.tokens()))
        await task.value
        #expect(store.activity == .idle)
        #expect(store.state.kind == .account)
    }

    @Test func signingInAgainReplacesTheOpenSignIn() async {
        let cancelled = Box(false)
        let first = Box(true)
        let (store, _) = store(
            FakeServices(browser: {
                guard first.value else { return Fixture.tokens("second") }
                first.update { $0 = false }
                return try await waitForCancellation(cancelled)
            }))
        let browser = store.startSignIn()
        await eventually { !first.value }
        await store.startSignIn().value
        await browser.value
        #expect(cancelled.value)
        #expect(vault.credential == .oauth(Fixture.tokens("second")))
        #expect(store.alert == nil)
    }

    @Test func signingInAgainClearsNeedsAttentionAndKeepsAccountInfo() async {
        let vault = FakeVault(.oauth(Fixture.tokens("old")))
        let metadata = FakeMetadataStore(ConnectionMetadata(kind: .account, displayName: "me@example.com", plan: "Pro"))
        let (store, recorder) = store(vault: vault, metadata: metadata)
        store.markNeedsAttention()
        #expect(store.needsAttention)
        await store.startSignIn().value
        #expect(!store.needsAttention)
        #expect(store.state == .account(AccountInfo(email: "me@example.com", plan: "Pro")))
        #expect(vault.credential == .oauth(Fixture.tokens()))
        #expect(recorder.credentials == [.oauth(Fixture.tokens())])
    }

    @Test func idTokenAccountIsShownAndPersisted() async {
        let tokens = Fixture.tokens(email: "me@example.com", name: "Me")
        let (store, _) = store(FakeServices(browser: { tokens }))
        await store.startSignIn().value
        #expect(store.state == .account(AccountInfo(email: "me@example.com", name: "Me")))
        let saved = ConnectionMetadata(kind: .account, displayName: "me@example.com", plan: nil, name: "Me")
        #expect(metadata.stored == saved)
        let (restarted, _) = self.store(vault: vault, metadata: metadata)
        #expect(restarted.state == .account(AccountInfo(email: "me@example.com", name: "Me")))
    }

    @Test func signingInAsAnotherAccountDropsThePlan() async {
        let vault = FakeVault(.oauth(Fixture.tokens("old")))
        let metadata = FakeMetadataStore(ConnectionMetadata(kind: .account, displayName: "me@example.com", plan: "Pro"))
        let other = Fixture.tokens(email: "other@example.com")
        let (store, _) = store(FakeServices(browser: { other }), vault: vault, metadata: metadata)
        await store.startSignIn().value
        #expect(store.state == .account(AccountInfo(email: "other@example.com")))
    }

    @Test func signingInAsTheSameAccountKeepsThePlan() async {
        let vault = FakeVault(.oauth(Fixture.tokens("old")))
        let metadata = FakeMetadataStore(ConnectionMetadata(kind: .account, displayName: "me@example.com", plan: "Pro"))
        let same = Fixture.tokens(email: "me@example.com", name: "Me")
        let (store, _) = store(FakeServices(browser: { same }), vault: vault, metadata: metadata)
        await store.startSignIn().value
        #expect(store.state == .account(AccountInfo(email: "me@example.com", name: "Me", plan: "Pro")))
    }

    @Test func storedTokensAreOfferedForClientReuse() async {
        let vault = FakeVault(.oauth(Fixture.tokens("old")))
        let services = FakeServices()
        let (store, _) = store(services, vault: vault)
        await store.startSignIn().value
        await store.startSignIn().value
        #expect(services.previous.value == [Fixture.tokens("old"), Fixture.tokens()])
    }

    @Test func freshSignInHasNoPreviousTokens() async {
        let services = FakeServices()
        let (store, _) = store(services, vault: FakeVault(.apiKey(id: "kid", secret: "s")))
        await store.startSignIn().value
        #expect(services.previous.value == [nil])
    }

    @Test func cancelingTheSheetCancelsTheBrowserSignIn() async {
        let cancelled = Box(false)
        let (store, _) = store(FakeServices(browser: { try await waitForCancellation(cancelled) }))
        let task = store.startSignIn()
        store.cancelSignIn()
        await task.value
        #expect(cancelled.value)
        #expect(store.alert == nil)
        #expect(store.activity == .idle)
    }

    @Test func refusedRefreshAsksToSignInAgain() async {
        let (store, _) = store(FakeServices(browser: { throw SignInError.reauthenticationRequired }))
        await store.startSignIn().value
        #expect(store.alert?.title == "Sign in again")
    }

    @Test func needsAttentionIsIgnoredWhenDisconnected() {
        let (store, _) = store()
        store.markNeedsAttention()
        #expect(!store.needsAttention)
    }

    @Test func updateAccountPersistsPlanButNotCredits() async {
        let (store, _) = store()
        await store.startSignIn().value
        store.updateAccount(AccountInfo(email: "me@example.com", plan: "Creator", credits: 1200))
        #expect(store.state == .account(AccountInfo(email: "me@example.com", plan: "Creator", credits: 1200)))
        #expect(metadata.stored == ConnectionMetadata(kind: .account, displayName: "me@example.com", plan: "Creator"))
    }

    // MARK: Balance

    @Test func balanceFillsInCreditsAndAMissingOneHidesThem() async throws {
        let (store, _) = store()
        await store.startSignIn().value

        await store.refreshBalance(from: BalanceProvider { .credits(1_250) })
        #expect(store.state.cardRows(capabilities: nil).contains { $0.label == "Credits" })
        let info = try #require(store.state.accountInfo)
        #expect(info.credits == 1_250)

        await store.refreshBalance(from: BalanceProvider { nil })
        #expect(!store.state.cardRows(capabilities: nil).contains { $0.label == "Credits" })

        await store.refreshBalance(from: BalanceProvider { .credits(7) })
        await store.refreshBalance(from: BalanceProvider { throw ProviderError.network })
        #expect(!store.state.cardRows(capabilities: nil).contains { $0.label == "Credits" })
    }

    @Test func balanceNamesThePlanAndAnAnswerWithoutOneKeepsIt() async throws {
        let (store, _) = store()
        await store.startSignIn().value

        await store.refreshBalance(from: BalanceProvider { .credits(10, plan: "creator_plus") })
        #expect(store.state.accountInfo?.plan == "Creator Plus")
        #expect(metadata.stored?.plan == "Creator Plus")

        await store.refreshBalance(from: BalanceProvider { .credits(9) })
        #expect(store.state.accountInfo?.plan == "Creator Plus")
        #expect(store.state.cardRows(capabilities: nil).contains { $0.label == "Plan" && $0.value == "Creator Plus" })
    }

    @Test func apiKeyHasNoBalanceRow() async {
        let (store, _) = store()
        await store.connectAPIKey(APIKeyForm(keyID: "kid", secret: "secret"))

        await store.refreshBalance(from: BalanceProvider(kind: .apiKey, owner: "kid") { .usd(12) })

        #expect(store.state == .apiKey(keyID: "kid"))
        #expect(!store.state.cardRows(capabilities: nil).contains { $0.label == "Credits" })
    }

    @Test func balanceReadForThePreviousSignInNeverLands() async throws {
        let (store, _) = store()
        await store.startSignIn().value
        let gate = Gate<Balance?>()
        let refresh = Task { await store.refreshBalance(from: BalanceProvider { try await gate.wait() }) }
        await eventually { await gate.isWaiting }

        await store.startSignIn().value
        await gate.open(.success(.credits(99)))
        await refresh.value

        let info = try #require(store.state.accountInfo)
        #expect(info.credits == nil)
    }

    @Test func signingInAgainDropsTheOldCredits() async throws {
        let (store, _) = store()
        await store.startSignIn().value
        await store.refreshBalance(from: BalanceProvider { .credits(500) })

        await store.startSignIn().value

        let info = try #require(store.state.accountInfo)
        #expect(info.credits == nil)
    }

    // MARK: Sign out

    @Test func signOutDeletesTheCredentialAndReportsNil() async {
        let vault = FakeVault(.apiKey(id: "kid", secret: "s"))
        let metadata = FakeMetadataStore(ConnectionMetadata(kind: .apiKey, displayName: "kid", plan: nil))
        let (store, recorder) = store(vault: vault, metadata: metadata)
        store.markNeedsAttention()
        await store.signOut()
        #expect(store.state == .none)
        #expect(!store.needsAttention)
        #expect(vault.credential == nil)
        #expect(metadata.stored == nil)
        #expect(recorder.credentials == [nil])
        let (restarted, _) = self.store(vault: vault, metadata: metadata)
        #expect(restarted.state == .none)
    }

    @Test func signOutRevokesTheAccountInTheBackground() async {
        let services = FakeServices()
        let (store, _) = store(services)
        await store.startSignIn().value

        await store.signOut()
        await store.revocation?.value

        #expect(services.revoked.value == [Fixture.tokens()])
    }

    @Test func removingAnAPIKeyRevokesNothing() async {
        let services = FakeServices()
        let vault = FakeVault(.apiKey(id: "kid", secret: "s"))
        let metadata = FakeMetadataStore(ConnectionMetadata(kind: .apiKey, displayName: "kid", plan: nil))
        let (store, _) = store(services, vault: vault, metadata: metadata)
        await store.signOut()
        #expect(store.revocation == nil)
        #expect(services.revoked.value.isEmpty)
    }

    // MARK: Refreshed tokens

    @Test func refreshForTheCurrentSignInIsSaved() async throws {
        let (store, _) = store()
        await store.startSignIn().value
        let refreshed = Fixture.tokens("access-2")

        let saved = try store.saveRefreshedTokens(refreshed, generation: store.credentialGeneration)
        #expect(saved)
        #expect(vault.credential == .oauth(refreshed))
    }

    @Test func refreshFinishingAfterSignOutIsDropped() async throws {
        let (store, _) = store()
        await store.startSignIn().value
        let generation = store.credentialGeneration
        await store.signOut()

        let saved = try store.saveRefreshedTokens(Fixture.tokens("access-2"), generation: generation)
        #expect(!saved)
        #expect(vault.credential == nil)
    }

    @Test func refreshOfThePreviousAccountIsDroppedAfterASwitch() async throws {
        let signIns = Box(0)
        let services = FakeServices(browser: {
            signIns.update { $0 += 1 }
            return signIns.value == 1
                ? Fixture.tokens("a", email: "a@example.com") : Fixture.tokens("b", email: "b@example.com")
        })
        let (store, _) = store(services)
        await store.startSignIn().value
        let first = store.credentialGeneration
        await store.startSignIn().value

        let saved = try store.saveRefreshedTokens(Fixture.tokens("a-2", email: "a@example.com"), generation: first)
        #expect(!saved)
        #expect(vault.credential == .oauth(Fixture.tokens("b", email: "b@example.com")))
    }

    @Test func accountTokensUnderAnotherAccountsNameAreNotRestored() {
        let vault = FakeVault(.oauth(Fixture.tokens(email: "a@example.com")))
        let metadata = FakeMetadataStore(ConnectionMetadata(kind: .account, displayName: "b@example.com", plan: nil))
        let (store, _) = store(vault: vault, metadata: metadata)
        #expect(store.state == .none)
    }

    @Test func aKeyUnderAnotherKeysNameIsNotRestored() {
        let vault = FakeVault(.apiKey(id: "other", secret: "s"))
        let metadata = FakeMetadataStore(ConnectionMetadata(kind: .apiKey, displayName: "kid", plan: nil))
        let (store, _) = store(vault: vault, metadata: metadata)
        #expect(store.state == .none)
    }

    @Test func failedDeleteKeepsTheConnection() async {
        let vault = FakeVault(.apiKey(id: "kid", secret: "s"))
        vault.failsDelete = true
        let metadata = FakeMetadataStore(ConnectionMetadata(kind: .apiKey, displayName: "kid", plan: nil))
        let (store, recorder) = store(vault: vault, metadata: metadata)
        await store.signOut()
        #expect(store.state == .apiKey(keyID: "kid"))
        #expect(store.alert != nil)
        #expect(recorder.credentials.isEmpty)
    }

    // MARK: Keychain read failures

    @Test func keychainFailingAtActivateDisconnectsWithAnAlert() async {
        let vault = FakeVault(.apiKey(id: "kid", secret: "s"))
        let metadata = FakeMetadataStore(ConnectionMetadata(kind: .apiKey, displayName: "kid", plan: nil))
        let (store, recorder) = store(vault: vault, metadata: metadata)
        vault.failsLoad = true

        await store.activate()

        #expect(store.state == .none)
        #expect(store.alert != nil)
        #expect(recorder.credentials == [nil])
        #expect(metadata.stored != nil)
    }

    @Test func keychainFailingAtSignInStopsBeforeTheBrowser() async {
        let services = FakeServices()
        vault.failsLoad = true
        let (store, recorder) = store(services)

        await store.startSignIn().value

        #expect(store.alert != nil)
        #expect(store.activity == .idle)
        #expect(services.previous.value.isEmpty)
        #expect(recorder.credentials.isEmpty)
    }

    @Test func signOutSaysWhenTheTokensCouldNotBeRevoked() async {
        let services = FakeServices()
        let (store, recorder) = store(services)
        await store.startSignIn().value
        vault.failsLoad = true

        await store.signOut()

        #expect(store.state == .none)
        #expect(store.alert == .notRevoked)
        #expect(store.revocation == nil)
        #expect(recorder.credentials.last == .some(nil))
    }
}

extension ConnectionState {
    fileprivate var accountInfo: AccountInfo? {
        if case .account(let info) = self { return info }
        return nil
    }
}

@MainActor
final class Recorder {
    var credentials: [Credential?] = []
    var keys: [String] = []
}
