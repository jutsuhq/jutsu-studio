import Foundation
import Persistence
import Presentation
import SwiftData

extension AppEnvironment {
    /// Stars or unstars `prompt`; a starred prompt stays on top of the history and survives clearing it.
    func setStarred(_ isStarred: Bool, prompt: String) throws {
        let text = PromptHistory.key(prompt)
        guard !text.isEmpty else { return }
        let context = modelContainer.mainContext
        let existing = try context.fetch(
            FetchDescriptor<StarredPromptRecord>(predicate: #Predicate { $0.text == text }))
        if isStarred {
            guard existing.isEmpty else { return }
            context.insert(StarredPromptRecord(text: text))
        } else {
            existing.forEach(context.delete)
        }
        try context.save()
    }
}
