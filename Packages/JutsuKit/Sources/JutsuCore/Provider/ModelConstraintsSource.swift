import Foundation

/// A provider that can say what each model takes, from the server rather than the app's constants. Slow and
/// rarely changing, so the app caches the answer and asks again at most once a day.
public protocol ModelConstraintsSource: Sendable {
    /// The server's constraints of the models the provider runs; `nil` when it has no way to tell.
    func modelConstraints() async throws -> ModelConstraintTable?
}
