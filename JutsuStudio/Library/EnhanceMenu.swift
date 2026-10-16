import HiggsfieldProviders
import JutsuCore
import Presentation
import SwiftUI

/// Enhance on a result's page: Upscale…, Reframe…, Remove Background…, Dub… and Change Voice…, operations of the
/// account's tools that make a new library item linked to this one. Hidden or off with the reason as
/// `EnhanceAvailability` says.
struct EnhanceMenu: View {
    let item: LibraryItemModel

    @Environment(ConnectionStore.self) private var connection
    @State private var request: EnhanceRequest?

    var body: some View {
        let availability = EnhanceAvailability.of(
            item, connection: connection.state.kind, offered: HiggsfieldMCPProvider.offersPostOperations)
        if availability != .hidden {
            let reason: String? =
                if case .disabled(let reason) = availability { reason } else { nil }
            Menu {
                Button("Upscale…", systemImage: "arrow.up.left.and.arrow.down.right") {
                    request = EnhanceRequest(action: .upscale(UpscaleOptions()))
                }
                Button("Reframe…", systemImage: "aspectratio") {
                    request = EnhanceRequest(action: .reframe(.portrait))
                }
                Button("Remove Background…", systemImage: "person.crop.rectangle") {
                    request = EnhanceRequest(action: .removeBackground)
                }
                Divider()
                Button("Dub…", systemImage: "character.bubble") {
                    request = EnhanceRequest(action: .dub(.english))
                }
                Button("Change Voice…", systemImage: "waveform") {
                    request = EnhanceRequest(kind: .changeVoice)
                }
            } label: {
                Label(PostOperationText.menuTitle, systemImage: "wand.and.rays").frame(maxWidth: .infinity)
            }
            .menuStyle(.button)
            .buttonStyle(.secondaryAction)
            .disabled(reason != nil)
            .hoverHint(reason ?? String(localized: "Upscale, reframe, dub and more"))
            .sheet(item: $request) { EnhanceSheet(item: item, kind: $0.kind, action: $0.action) }
        }
    }
}

private struct EnhanceRequest: Identifiable {
    let id = UUID()
    let kind: PostAction.Kind
    /// The options the sheet opens with; `nil` for Change Voice, which has none until a voice is picked.
    let action: PostAction?

    init(action: PostAction) {
        kind = action.kind
        self.action = action
    }

    init(kind: PostAction.Kind) {
        self.kind = kind
        action = nil
    }
}

/// "Upscaled from rooftop" on a result an operation made, opening the result it was made from.
struct MadeFromLink: View {
    let item: LibraryItemModel
    let parent: LibraryItemModel?
    let open: (UUID) -> Void

    var body: some View {
        if let action = item.spec.operation?.action, let parentID = item.job.parentID {
            let name = parent?.sourceName ?? String(localized: "a deleted result")
            Button {
                open(parentID)
            } label: {
                Label(action.madeFrom(name), systemImage: "arrow.turn.left.up")
            }
            .buttonStyle(.link)
            .disabled(parent == nil)
        }
    }
}
