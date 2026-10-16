import Foundation
import JutsuCore
import Presentation
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "ModelConstraints")

extension AppEnvironment {
    /// Shows the cached model constraints of the provider's account, then reads them again if they are a day old.
    /// A connection that can't report them (an API key), or an account that can't be identified, uses the constants.
    func loadModelConstraints() async {
        let account: String? =
            if let provider, modelConstraintsSource != nil, let owner = provider.owner {
                "\(provider.kind.rawValue)|\(owner)"
            } else {
                nil
            }
        await modelConstraints.switchAccount(to: account)
        refreshModelConstraints()
    }

    /// Reads the constraints from the server when the cached ones are a day old or missing; otherwise nothing.
    /// Called on connect and with the capabilities, never on a form edit.
    func refreshModelConstraints() {
        guard let source = modelConstraintsSource, modelConstraints.isStale else { return }
        Task { [modelConstraints] in
            await modelConstraints.refreshIfStale { try await source.modelConstraints() }
        }
    }

    /// Hands a new table to the Create form; in Debug, logs where it differs from the constants, so a server change
    /// gets noticed.
    func useModelConstraints(_ table: ModelConstraintTable) {
        navigation.useModelConstraints(table)
        #if DEBUG
            for difference in table.differencesFromBuiltIn {
                logger.notice("models_explore differs from the built-in limits: \(difference, privacy: .public)")
            }
        #endif
    }
}
