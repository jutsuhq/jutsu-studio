import AppKit
import JutsuCore
import MediaKit
import Persistence
import Presentation
import SwiftUI

/// One result on its own page: a large before/after player beside the prompt, inputs and follow-ups.
/// The arrow keys step through the results the grid shows; Escape goes back to it.
struct LibraryDetail: View {
    let item: LibraryItemModel
    let record: MaterialRecord?
    /// 1-based place of the item among the grid's results, and how many there are.
    let position: Int
    let count: Int
    /// The draft-to-final chain the item belongs to.
    let chain: LibraryChain
    /// The result this one was made from, while it is in the library.
    let parent: LibraryItemModel?
    /// The images the result was made from, with their roles (`MaterialRelations.madeFrom`).
    let madeFrom: [MaterialLink]
    /// Shows the details of a source image's exact version.
    let showImage: (MaterialReference) -> Void
    let step: (Int) -> Void
    /// Opens another result, e.g. a step of the chain.
    let open: (UUID) -> Void
    /// What "Compare with…" offers.
    let compareCandidates: [LibraryItemModel]
    /// Opens the compare page with this item on the left.
    let compare: (LibraryItemModel) -> Void
    let close: () -> Void
    /// Whether the result made the cut, and what Keep, Reject and Clear do; the culling keys work here too.
    let culling: Culling
    let cull: (CullingAction) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(ConnectionStore.self) private var connection
    @Environment(NavigationModel.self) private var navigation
    @Environment(LiveJobs.self) private var liveJobs

    @State private var finalResolution = Resolution.p720
    @State private var estimatedFinal: Cost?
    @State private var submitting = SubmitController()
    @State private var isConfirmingDelete = false
    @State private var message: UserMessage?
    @State private var pricing = try? Pricing.bundled()
    @State private var isNamingTemplate = false
    @State private var templateName = ""
    @State private var duplicateRequest: JobSpec?
    @State private var isJoining = false

    private var aspect: CGFloat { CGFloat(item.aspectRatio ?? 16 / 9) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            topBar
            GeometryReader { proxy in
                // Side by side while the player keeps a useful size; stacked in a narrow window.
                if proxy.size.width >= (aspect < 1 ? 600 : 780) {
                    HStack(alignment: .top, spacing: Theme.Spacing.xLarge) {
                        ResultStage(item: item, aspect: aspect)
                        ScrollView { details }
                            .scrollIndicators(.never)
                            .frame(width: 320)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
                            ResultStage(item: item, aspect: aspect).frame(height: 380)
                            details
                        }
                    }
                    .scrollIndicators(.never)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.top, Theme.Spacing.pageTop)
        .padding(.bottom, Theme.Spacing.page)
        .libraryCommands(menuCommands)
        .task(id: item.id) {
            // A draft Higgsfield can finalize opens on its finalize.
            if item.job.finalizeSpec(owner: environment.provider?.owner) != nil { finalResolution = .p1080 }
        }
        .confirmationDialog(
            LibraryDeleteConfirmation.title, isPresented: $isConfirmingDelete, titleVisibility: .visible
        ) {
            Button(LibraryDeleteConfirmation.confirmTitle, role: .destructive, action: delete)
        } message: {
            Text(LibraryDeleteConfirmation.message)
        }
        .submitConfirmation(submitting, confirmTitle: String(localized: "Render Anyway"))
        .duplicating($duplicateRequest)
        .templateNameAlert(
            String(localized: "Save as Template"), isPresented: $isNamingTemplate, name: $templateName,
            confirmTitle: String(localized: "Save"),
            onConfirm: saveTemplate
        )
        .alert(message?.title ?? "", isPresented: Binding(isPresenting: $message), presenting: message) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message.message)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: Theme.Spacing.small) {
            Button("Library", systemImage: "chevron.left", action: close)
                .buttonStyle(.secondaryAction)
                .keyboardShortcut(.cancelAction)
                .hoverHint("Back to Library (Esc)")
            Spacer(minLength: Theme.Spacing.small)
            if count > 1 {
                ResultPager(position: position, count: count, step: step)
                    .padding(.trailing, Theme.Spacing.medium)
            }
            HStack(spacing: 6) { CullingButtons(count: 1, current: culling, act: cull) }
                .buttonStyle(.iconAction)
            starButton
            HStack(spacing: 6) {
                Button("Show in Finder", systemImage: "folder") {
                    if let url = item.outputFile { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                .hoverHint("Show in Finder")
                Button("Copy Video", systemImage: "doc.on.doc") {
                    if let url = item.outputFile { NSPasteboard.general.copyFiles([url]) }
                }
                .hoverHint("Copy video")
            }
            .disabled(item.outputFile == nil)
            .buttonStyle(.iconAction)
            EditingExportButton(item: item)
            moreMenu
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Duplicate", systemImage: "plus.square.on.square") { duplicateRequest = item.spec }
                .disabled(!connection.state.isConnected || duplicateRequest != nil)
            SeedanceFollowUpButtons(item: item)
            if let url = item.outputFile { ShareFilesLink(files: [url]) }
            if !item.spec.prompt.isEmpty {
                Button("Copy Prompt", systemImage: "text.quote") { copy(item.spec.prompt) }
            }
            if let remote = item.job.remote {
                Button("Copy Request ID", systemImage: "number") { copy(remote.requestID) }
            }
            compareMenu
            Button("Save as Template…", systemImage: "square.stack") {
                templateName = TemplateNaming.suggestedName(mode: item.spec.mode, prompt: item.spec.prompt)
                isNamingTemplate = true
            }
            Divider()
            Button("Delete from Library…", systemImage: "trash", role: .destructive) {
                isConfirmingDelete = true
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.iconAction)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverHint("More")
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            ResultSummary(item: item, aspect: aspect)
            if !chain.isEmpty { ChainSteps(chain: chain, open: open) }
            MadeFromLink(item: item, parent: parent, open: open)
            MadeFromImages(links: madeFrom, open: showImage)
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                if item.canRenderFinal {
                    RenderFinalSection(
                        item: item, finalResolution: $finalResolution, estimatedFinal: $estimatedFinal,
                        pricing: pricing, kind: connection.state.kind, provider: environment.provider,
                        owner: environment.provider?.owner, isWorking: submitting.isBusy,
                        isConnected: connection.state.isConnected,
                        onRender: { enqueueFinal(cost: $0) })
                }
                // An operation's spec re-runs as the operation, not as the generation Edit & Re-run loads.
                if item.spec.operation == nil { editButton }
                EnhanceMenu(item: item, version: (try? record?.material())?.reference)
                OnDeviceRunRow(materialID: item.id)
                if JoinWithOriginal.isAvailable(for: item) {
                    joinButton
                }
            }
            RecordLines(item: item)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The main follow-up for a final; second to "Render final" for a draft.
    @ViewBuilder
    private var editButton: some View {
        let button = Button {
            navigation.edit(item.spec, parentID: item.id)
        } label: {
            Label("Edit & Re-run", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity)
        }
        if item.canRenderFinal {
            button.buttonStyle(.secondaryAction)
        } else {
            button.buttonStyle(.primaryAction)
        }
    }

    /// The API returns only the part Extend added; this puts the source selection in front of it.
    private var joinButton: some View {
        Button {
            guard !isJoining else { return }
            isJoining = true
            Task {
                defer { isJoining = false }
                message = await JoinWithOriginal.run(for: item, catalog: environment.store)
            }
        } label: {
            Label("Join with Original…", systemImage: "rectangle.on.rectangle").frame(maxWidth: .infinity)
        }
        .buttonStyle(.secondaryAction)
        .disabled(isJoining)
        .hoverHint("Join into one video")
    }

    // MARK: Actions

    /// The final at the picked resolution; at 1080p a native draft's finalize (`LibraryItemModel.finalSpec(at:owner:now:)`).
    private var finalSpec: JobSpec { item.finalSpec(at: finalResolution, owner: environment.provider?.owner) }

    private func enqueueFinal(cost: Cost?) {
        let spec = finalSpec
        let submitting = submitting
        submitting.run {
            await submitting.handle(
                await environment.submitDecision(for: spec, cost: cost),
                blocked: { message = UserMessage(title: String(localized: "Can't queue the final"), message: $0) }
            ) { _, approved in
                await enqueue(spec, overCapApproved: approved)
            }
        }
    }

    /// - Parameter overCapApproved: the user confirmed going over today's cap.
    private func enqueue(_ spec: JobSpec, overCapApproved: Bool = false) async {
        if let error = await pipeline.enqueue([spec], parentID: item.id, overCapApproved: overCapApproved) {
            message = error
        }
    }

    private var pipeline: SubmitPipeline {
        SubmitPipeline(environment: environment, connection: connection)
    }

    /// A draft's inputs are saved at the resolution picked for its final.
    private func saveTemplate() {
        let spec = item.templateSpec(finalResolution: finalResolution)
        do {
            try environment.saveTemplate(JobTemplate(name: templateName, spec: spec))
        } catch {
            message = .templateNotSaved(error)
        }
    }

    private func delete() {
        let records = record.map { [$0] } ?? []
        Task {
            if let failure = await environment.deleteFromLibrary([item], records: records) {
                message = failure
            } else {
                close()
            }
        }
    }
}

extension LibraryDetail {
    @ViewBuilder fileprivate var compareMenu: some View {
        if item.outputFile != nil, !compareCandidates.isEmpty {
            Menu("Compare with…", systemImage: "rectangle.split.2x1") {
                ForEach(compareCandidates) { candidate in
                    Button(ComparePair.menuTitle(for: candidate)) { compare(candidate) }
                }
            }
        }
    }

    fileprivate var starButton: some View {
        Button(
            item.isStarred ? "Unstar" : "Star", systemImage: item.isStarred ? "star.fill" : "star", action: toggleStar
        )
        .buttonStyle(.iconAction)
        .foregroundStyle(item.isStarred ? Theme.accent : Theme.muted)
        .disabled(record == nil)
        .hoverHint(item.isStarred ? "Unstar" : "Star")
    }

    /// The Library menu on this page: the star button, the Render final button and Delete from the More menu.
    fileprivate var menuCommands: LibraryCommands {
        let targets = LibraryMenuTargets([item]) { _ in record != nil }
        let finalSpec = finalSpec
        let canRender =
            targets.renderFinal != nil && !submitting.isBusy && connection.state.isConnected
            && liveJobs.activeJob(parentID: item.id, spec: finalSpec) == nil
        let price =
            item.finalPrice(at: finalResolution, pricing: pricing, connection: connection.state.kind) ?? estimatedFinal
        var commands = LibraryCommands()
        if !targets.starrable.isEmpty {
            commands.star = MenuCommand(title: targets.starTitle) { toggleStar() }
        }
        if canRender {
            commands.renderFinal = MenuCommand(title: String(localized: "Render Final")) { enqueueFinal(cost: price) }
        }
        if !targets.deletable.isEmpty {
            commands.delete = { isConfirmingDelete = true }
        }
        return commands
    }

    fileprivate func toggleStar() {
        let item = item
        let record = record
        Task {
            do {
                try await environment.setStarred(!item.isStarred, for: item, record: record)
            } catch {
                message = .likeNotSaved(error)
            }
        }
    }

    fileprivate func copy(_ text: String) {
        NSPasteboard.general.copyText(text)
    }
}
