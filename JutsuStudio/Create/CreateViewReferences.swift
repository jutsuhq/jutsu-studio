import JutsuCore
import Presentation
import SwiftUI

// Generate… for References on the Create screen: its loads, its sheet and the generated images it adds.
extension CreateView {
    /// Generate…'s loads, kept off `body`'s modifier chain so it type-checks in time. Behind the header, so both
    /// sides share them.
    var referenceGenerationLoads: some View {
        Color.clear
            .task(id: environment.providerGeneration) {
                await environment.loadImageModels()
            }
            // A reference image request counts toward today from its submit until it is taken off again.
            .task(id: environment.imageSpend.charges.map(\.id)) {
                await loader.refreshCommitted(environment, unit: spendCap?.unit ?? .usd)
            }
    }

    /// Generate…'s sheet for the References quick action, kept off `body`'s modifier chain so it type-checks
    /// in time.
    var referenceGenerationHost: some View {
        Color.clear
            .sheet(isPresented: $isGeneratingReferences) {
                let form = navigation.createDraft
                GenerateReferenceSheet(
                    source: form.source?.pixelSize, mode: form.mode, room: form.referenceRoom,
                    adding: addingGenerated, onAdd: { await addGenerated($0) })
            }
    }

    /// Generate… for References; `nil` while disconnected.
    var referenceGeneration: ReferenceGeneration? {
        guard environment.imageProvider != nil else { return nil }
        return ReferenceGeneration(
            disabledReason: environment.referenceGenerationBlocker, onOpen: { isGeneratingReferences = true })
    }

    /// Downloads a generated image and adds it like an opened file; the message says why it wasn't added.
    private func addGenerated(_ image: GeneratedImage) async -> UserMessage? {
        guard addingGenerated.insert(image.id).inserted else { return nil }
        defer { addingGenerated.remove(image.id) }
        return await environment.addGenerated(image, to: navigation)
    }
}
