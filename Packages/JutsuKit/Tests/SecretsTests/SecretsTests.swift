import Foundation
import Secrets
import Security
import Testing

private func makeTestStore() -> KeychainStore {
    KeychainStore(service: "com.jutsustudio.tests.\(UUID().uuidString)", account: "active")
}

@Suite struct KeychainStoreTests {
    @Test func roundTripsData() throws {
        let store = makeTestStore()
        defer { try? store.delete() }

        try store.saveData(Data("secret-1".utf8))
        #expect(try store.loadData() == Data("secret-1".utf8))

        try store.delete()
        #expect(try store.loadData() == nil)
    }

    @Test func saveOverwritesExistingItem() throws {
        let store = makeTestStore()
        defer { try? store.delete() }

        try store.saveData(Data("first".utf8))
        try store.saveData(Data("second".utf8))
        #expect(try store.loadData() == Data("second".utf8))
    }

    @Test func missingItemLoadsAsNil() throws {
        #expect(try makeTestStore().loadData() == nil)
    }

    @Test func deleteIsIdempotent() throws {
        let store = makeTestStore()
        try store.delete()
        try store.saveData(Data("x".utf8))
        try store.delete()
        try store.delete()
        #expect(try store.loadData() == nil)
    }

    @Test func storesAreIsolatedByService() throws {
        let first = makeTestStore()
        let second = makeTestStore()
        defer {
            try? first.delete()
            try? second.delete()
        }

        try first.saveData(Data("first".utf8))
        #expect(try second.loadData() == nil)
    }

    @Test func activeConnectionUsesDocumentedItem() {
        #expect(KeychainStore.activeConnection.service == "com.jutsustudio.connection")
        #expect(KeychainStore.activeConnection.account == "active")
        #expect(KeychainStore.activeConnection.accessGroup == nil)
        #expect(KeychainStore.developmentConnection.service == "com.jutsustudio.connection.debug")
        #expect(KeychainStore.developmentConnection.account == "active")
    }
}

@Suite struct KeychainErrorTests {
    @Test func describesStatus() {
        let error = KeychainError(status: errSecDuplicateItem)
        #expect(error.description.contains("\(errSecDuplicateItem)"))
        #expect(error.localizedDescription == error.description)
    }

    @Test func describesUnknownStatus() {
        #expect(KeychainError(status: -999_999).description.contains("-999999"))
    }
}
