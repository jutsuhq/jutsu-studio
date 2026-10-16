import Foundation

/// Storage for one secret value.
public protocol SecretStore: Sendable {
    /// Replaces the stored value.
    func saveData(_ data: Data) throws
    /// The stored value, or nil when nothing is stored. Throws when the Keychain itself fails,
    /// which callers must not treat as signed out.
    func loadData() throws -> Data?
    /// Removes the stored value. Deleting when nothing is stored is not an error.
    func delete() throws
}
