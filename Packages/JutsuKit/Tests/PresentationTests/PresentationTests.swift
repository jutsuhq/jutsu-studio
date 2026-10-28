import Foundation
import JutsuCore
import Testing

@testable import Presentation

@Suite struct APIKeyFormTests {
    @Test(arguments: [("", "s"), ("kid", ""), (" ", "s"), ("kid", " \n")])
    func blankFieldsAreIncomplete(keyID: String, secret: String) {
        let form = APIKeyForm(keyID: keyID, secret: secret)
        #expect(form.credential == nil)
        #expect(!form.isComplete)
    }
}

@Suite struct UserMessageTests {
    @Test func cancellationAndConcurrencyAreSilent() {
        #expect(UserMessage(CancellationError()) == nil)
        #expect(UserMessage(ProviderError.concurrencyLimit(retryAfter: 30)) == nil)
    }

    @Test func unauthorizedDependsOnTheConnection() {
        #expect(UserMessage(ProviderError.unauthorized, kind: .apiKey)?.title == "API key is invalid")
        #expect(UserMessage(ProviderError.unauthorized)?.title == "API key is invalid")
        #expect(UserMessage(ProviderError.unauthorized, kind: .account)?.title == "Sign in again")
        #expect(UserMessage(ProviderError.unauthorized)?.action == .openSettings)
    }

    @Test func insufficientFundsLinksTheConsoleForAPIKeys() {
        #expect(UserMessage(ProviderError.insufficientFunds, kind: .apiKey)?.title == "Not enough balance")
        #expect(UserMessage(ProviderError.insufficientFunds, kind: .apiKey)?.action == .openConsole)
        #expect(UserMessage(ProviderError.insufficientFunds, kind: .account)?.title == "Not enough credits")
    }

    @Test func validationNamesTheField() {
        let message = UserMessage(ProviderError.validation(field: "prompt", message: "too long"))
        #expect(message?.message == "prompt: too long")
        #expect(UserMessage(ProviderError.validation(field: nil, message: "bad"))?.message == "bad")
    }

    @Test func fixedTextsFromFeatures() {
        #expect(UserMessage(ProviderError.modelUnavailable)?.title == "Model temporarily unavailable")
        #expect(UserMessage(ProviderError.rejected)?.title == "Rejected by content moderation")
        #expect(UserMessage(ProviderError.rejected)?.message == "You were not charged.")
        #expect(UserMessage(ProviderError.server(status: 502))?.message.contains("502") == true)
    }

    @Test(arguments: [
        SignInError.unavailable, .flowUnavailable, .denied, .timedOut, .invalidResponse,
        .reauthenticationRequired,
        .server(nil), .server("Client not allowed"),
    ])
    func everySignInErrorHasAMessage(error: SignInError) throws {
        let message = try #require(UserMessage(error))
        #expect(!message.title.isEmpty)
        #expect(!message.message.isEmpty)
    }

    @Test func serverDescriptionIsShown() {
        #expect(UserMessage(SignInError.server("Client not allowed"))?.message == "Client not allowed")
    }

    @Test func unknownErrorsStillGetAMessage() {
        #expect(UserMessage(CocoaError(.fileNoSuchFile))?.title == "Something went wrong")
    }
}

@Suite struct SignOutConfirmationTests {
    @Test func signOutTextsMatchTheConnection() {
        #expect(SignOutConfirmation(.none) == nil)
        let key = SignOutConfirmation(.apiKey(keyID: "kid"))
        #expect(key?.title == "Remove the API key?")
        #expect(key?.confirmTitle == "Remove")
        #expect(key?.message.contains("Keychain") == true)
        let account = SignOutConfirmation(.account(AccountInfo()))
        #expect(account?.title == "Sign out of Higgsfield?")
        #expect(account?.confirmTitle == "Sign Out")
    }
}

@Suite struct ModeOptionTests {
    let allModes = Capabilities(
        modes: Set(Mode.allCases), resolutions: Set(Resolution.allCases), costUnit: .usd, maxConcurrency: nil)

    @Test func everythingIsDisabledWithoutAConnection() {
        let options = ModeOption.all(for: .none, capabilities: allModes)
        #expect(options.map(\.mode) == Mode.allCases)
        #expect(options.allSatisfy { $0.unavailableReason == "Connect Higgsfield first" })
    }

    @Test func modesWaitForCapabilities() {
        let options = ModeOption.all(for: .apiKey(keyID: "kid"), capabilities: nil)
        #expect(options.allSatisfy { !$0.isAvailable })
    }

    @Test func modesTheAccountLacksSayWhy() {
        let capabilities = Capabilities(
            modes: [.motionTransfer], resolutions: [.p480], costUnit: .credits, maxConcurrency: nil)
        let options = ModeOption.all(for: .account(AccountInfo()), capabilities: capabilities)
        #expect(options.filter { $0.isAvailable }.map(\.mode) == [.motionTransfer])
        #expect(options.first { $0.mode == .restyle }?.unavailableReason == "Not available for this account")
        #expect(options.first { $0.mode == .edit }?.unavailableReason == "Not available for this account")
    }

    @Test func allModesRunWithAFullAPIKey() {
        #expect(ModeOption.all(for: .apiKey(keyID: "kid"), capabilities: allModes).allSatisfy { $0.isAvailable })
    }
}

extension UserDefaultsBackedTests {
    @Suite struct DefaultsTests {
        func defaults() throws -> UserDefaults {
            let name = "PresentationTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: name))
            defaults.removePersistentDomain(forName: name)
            return defaults
        }

        @Test func metadataRoundTripsAndClears() throws {
            let store = UserDefaultsMetadataStore(defaults: try defaults())
            #expect(store.load() == nil)
            let metadata = ConnectionMetadata(kind: .account, displayName: "me@example.com", plan: "Pro")
            store.save(metadata)
            #expect(store.load() == metadata)
            store.clear()
            #expect(store.load() == nil)
        }
    }
}
