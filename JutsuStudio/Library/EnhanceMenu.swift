import HiggsfieldProviders
import JutsuCore
import Presentation
import SwiftUI

/// Enhance on a result's page: Upscale…, Reframe…, Remove Background…, Dub… and Change Voice…, operations of the
/// account's tools that make a new library item linked to this one, hidden or off with the reason as
/// `EnhanceAvailability` says; and Smooth Motion…, which runs on this Mac (`OnDeviceOffer`), is free and adds the
/// result as a new version of this item.
struct EnhanceMenu: View {
    let item: LibraryItemModel
    /// The version on the page, which a run on this Mac is made from; `nil` when the catalog can't say.
    let version: MaterialReference?

    @Environment(AppEnvironment.self) private var environment
    @Environment(ConnectionStore.self) private var connection
    @State private var request: EnhanceRequest?
    @State private var onDevice: OnDeviceTarget?

    var body: some View {
        let availability = EnhanceAvailability.of(
            item, connection: connection.state.kind, offered: HiggsfieldMCPProvider.offersPostOperations)
        let local = version == nil ? .none : OnDeviceOffer.of(item, supports: environment.onDevice.supports)
        // One run on this Mac at a time per item: the next waits until this one's version is in.
        let running = version.flatMap { environment.onDevice.run(for: $0.materialID) }
        if availability != .hidden || !local.isEmpty {
            let reason: String? =
                if case .disabled(let reason) = availability { reason } else { nil }
            Menu {
                if let running {
                    Section(OnDeviceText.busy(running)) { localItems(local).disabled(true) }
                } else {
                    localItems(local)
                }
                if availability != .hidden {
                    if !local.isEmpty { Divider() }
                    if let reason {
                        Section(reason) { remoteItems.disabled(true) }
                    } else {
                        remoteItems
                    }
                }
            } label: {
                Label(PostOperationText.menuTitle, systemImage: "wand.and.rays").frame(maxWidth: .infinity)
            }
            .menuStyle(.button)
            .buttonStyle(.secondaryAction)
            .disabled(reason != nil && local.isEmpty)
            .hoverHint(hint(availability: availability, reason: reason, local: local))
            .sheet(item: $request) { EnhanceSheet(item: item, kind: $0.kind, action: $0.action) }
            .sheet(item: $onDevice) { OnDeviceEnhanceSheet(target: $0) }
        }
    }

    /// What the menu offers: the account's tools, or only this Mac's when those are hidden or off.
    private func hint(availability: EnhanceAvailability, reason: String?, local: OnDeviceOffer) -> String {
        if availability == .available { return String(localized: "Upscale, reframe, dub and more") }
        return local.isEmpty ? reason ?? "" : OnDeviceText.menuHint(local)
    }

    @ViewBuilder private func localItems(_ local: OnDeviceOffer) -> some View {
        if local.smoothMotion {
            Button("Smooth Motion…", systemImage: "film.stack") { open(.smoothMotion) }
        }
    }

    @ViewBuilder private var remoteItems: some View {
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
    }

    private func open(_ kind: OnDeviceTarget.Kind) {
        guard let version, let file = item.outputFile else { return }
        onDevice = OnDeviceTarget(kind: kind, source: version, file: file, title: item.title)
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
