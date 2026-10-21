import AppKit
import JutsuCore
import MediaKit
import Presentation
import SwiftUI
import UniformTypeIdentifiers

/// The Create screen, on its Video or Image side. Video: the form on the left, the source preview and trim strip on
/// the right; all decisions come from `CreateForm`, and this view loads what it needs and queues the job. Image:
/// Generate…'s form and results (`CreateImageSide`).
struct CreateView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(NavigationModel.self) private var navigation
    @Environment(ConnectionStore.self) private var connection
    // Read only so the cap line updates when Settings changes; the value comes from `AppSettings.spendCap`.
    @AppStorage(AppSettings.spendCapEnabledKey) private var capEnabled = AppSettings.defaultSpendCapEnabled
    @AppStorage(AppSettings.spendCapUSDKey) private var capUSD = AppSettings.defaultSpendCapUSD
    @AppStorage(AppSettings.spendCapCreditsEnabledKey) private var creditCapEnabled =
        AppSettings.defaultSpendCapCreditsEnabled
    @AppStorage(AppSettings.spendCapCreditsKey) private var capCredits = AppSettings.defaultSpendCapCredits
    @AppStorage(AppSettings.draftResolutionKey) private var draftResolution = AppSettings.defaultDraftResolution
    @AppStorage(AppSettings.useUnlimitedKey) private var useUnlimited = AppSettings.defaultUseUnlimited

    @State private var loader = CreateLoader()
    @State private var submitting = SubmitController()
    @State private var alert: UserMessage?
    @State private var isPicking = false
    @State private var pickTarget = FilePickTarget.source
    /// The in-flight source probe, cancelled when the next pick supersedes it. It finishes after a tab
    /// switch, so a picked source isn't dropped.
    /// Enqueues are user-initiated engine work and intentionally run on without a slot.
    @State private var probeTask: Task<Void, Never>?
    /// The connection's Motion Library, shown on the empty stage; `nil` without one.
    @State private var library: MotionLibraryModel?
    /// The library clip being downloaded to become the source.
    @State private var downloadingClip: String?
    /// The account's uploaded images, offered as references; `nil` without an account connection.
    @State private var uploads: PagedFeed<UploadedFile>?
    /// The account's elements, offered beside the uploads; `nil` without an account connection.
    @State private var elements: AccountElementsModel?
    @State private var isBrowsingUploads = false
    /// The link being downloaded from Paste URL… or ⌘V, and its task; one at a time.
    @State private var linkDownload: LinkDownload?
    @State private var linkTask: Task<Void, Never>?
    /// The kind Paste URL… asks a link for while its field is open.
    @State private var linkEntry: MediaLink.Kind?
    @State private var linkText = ""
    @State private var isGeneratingReferences = false
    /// Generated images being downloaded to become references.
    @State private var addingGenerated: Set<UUID> = []
    /// The Image side's Generate: the price, the cap question and the result shown large.
    @State private var imageController = ImageGenerateController()

    private var context: CreateContext {
        CreateContext(
            connection: connection.state, capabilities: loader.capabilities, pricing: loader.pricing,
            estimates: loader.estimates.costs, lastTotals: loader.estimates.lastTotals,
            committedToday: loader.committedToday, cap: spendCap, unlimitedOptIn: useUnlimited)
    }

    var body: some View {
        @Bindable var navigation = navigation
        let form = $navigation.createDraft
        VStack(alignment: .leading, spacing: 0) {
            CreateHeader(form: form.wrappedValue, offeredModels: context.offeredModels)
                .background { referenceGenerationLoads }
            if navigation.createKind == .image {
                CreateImageSide(controller: imageController)
            } else {
                videoSide(form)
            }
        }
        .pagePadding()
        .background(Theme.background)
        .navigationTitle("Create")
        // SwiftUI handles only one `.fileImporter` per hierarchy reliably, so every picker on this
        // screen goes through this one.
        .fileImporter(
            isPresented: $isPicking, allowedContentTypes: pickTarget.contentTypes,
            allowsMultipleSelection: pickTarget.allowsMultipleSelection
        ) { result in
            guard case .success(let urls) = result else { return }
            picked(urls, for: pickTarget)
        }
        // Keyed by the provider, not `connection.state`, which also changes with each balance refresh.
        // Independent: a slow capability check must not keep the style gallery spinning.
        .task(id: environment.providerGeneration) {
            await loader.refreshCapabilities(environment)
        }
        .task(id: environment.providerGeneration) {
            await loader.refreshPresets(environment)
        }
        .task(id: environment.providerGeneration) {
            library = environment.motionLibrary.map(MotionLibraryModel.init)
            uploads = environment.uploadedImagesFeed()
            elements = environment.accountElementsModel()
        }
        .sheet(isPresented: $isBrowsingUploads) {
            if let uploads {
                HiggsfieldReferencesSheet(
                    uploads: uploads, elements: elements, offersCharacters: environment.characterMaker != nil,
                    limit: navigation.createDraft.referenceRoom
                ) {
                    navigation.createDraft.addReferences($0)
                }
            }
        }
        .task(id: spendCap) {
            await loader.refreshCommitted(environment, unit: spendCap?.unit ?? .usd)
        }
        .task(id: draftResolution) {
            navigation.createDraft.draftResolution = draftResolution
        }
        .task(id: navigation.pendingEdit) {
            await takePendingEdit()
        }
        .task(id: loader.capabilities?.models) {
            navigation.createDraft.fitModel(to: loader.capabilities?.models)
        }
        .task(id: navigation.pendingOpens) {
            takePendingOpens()
        }
        .task(id: estimateRequest) {
            await loader.loadEstimates(estimateRequest, environment: environment)
        }
        .focusedSceneValue(\.createSubmit, menuSubmit)
        // ⌘V: a copied image becomes a reference, a copied video the source. Text being edited pastes as usual.
        .background {
            TextAwareShortcut("Paste", key: "v", textAction: #selector(NSText.paste(_:))) { paste() }
        }
        .submitConfirmation(submitting, titleVisibility: .automatic)
        .alert(alert?.title ?? "", isPresented: Binding(isPresenting: $alert), presenting: alert) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message.message)
        }
    }

    // MARK: Loading

    /// Credit prices exist only as provider estimates; USD comes from the bundled table.
    private var estimateRequest: EstimateRequest? {
        guard context.costUnit == .credits else { return nil }
        return EstimateRequest(navigation.createDraft, context: context, generation: environment.providerGeneration)
    }

    /// Inputs another screen asked to edit (Queue "Edit inputs", Library "Render final").
    private func takePendingEdit() async {
        guard let spec = navigation.pendingEdit else { return }
        // Cleared only once loaded: clearing changes the task id, which would cancel the probe.
        var video: SourceVideo?
        if let clip = spec.source {
            video = await withScopedAccess(to: clip.fileURL, bookmark: clip.bookmark) { access in
                try? await AppEnvironment.probeSource(access.url, bookmark: access.refreshedBookmark ?? clip.bookmark)
            }
        }
        guard !Task.isCancelled, navigation.pendingEdit == spec else { return }
        let (parentID, models) = (navigation.pendingEditParent, loader.capabilities?.models)
        let fallback = navigation.replaceDraft { form in
            form.load(spec, source: video, parentID: parentID)
            return form.fitModel(to: models)
        }
        navigation.pendingEdit = nil
        navigation.pendingEditParent = nil
        // A missing source is the one to fix first; the model the form fell back to shows in its picker.
        alert = fallback
        if video == nil, spec.source != nil {
            alert = UserMessage(
                title: String(localized: "Can't open the source video"),
                message: String(localized: "Add the video again to queue this job."))
        }
    }

    /// Files opened from Finder or the Dock: a video becomes the source, images become references.
    private func takePendingOpens() {
        guard let request = navigation.pendingOpens.take() else { return }
        alert = request.unsupportedMessage
        if !request.images.isEmpty {
            let message = navigation.createDraft.addOpenedReferences(ReferencesSection.references(request.images))
            alert = message ?? alert
        }
        if let video = request.video { importSource(video) }
    }

    // MARK: Actions

    private func pick(_ target: FilePickTarget) {
        pickTarget = target
        isPicking = true
    }

    private func picked(_ urls: [URL], for target: FilePickTarget) {
        switch target {
        case .source:
            if let url = urls.first { importSource(url) }
        case .references:
            navigation.createDraft.addReferences(ReferencesSection.references(urls))
        case .characterSet:
            addCharacter(urls)
        case .frame(let slot):
            navigation.createDraft.setFrame(ReferencesSection.references(urls).first, for: slot)
        }
    }

    private func importSource(_ url: URL, origin: URL? = nil) {
        // Access lasts for the probe only; the preview and the job reopen the file through the bookmark,
        // which has to be made while access is held.
        let access = SecurityScopedAccess(url: url, bookmark: nil)
        let bookmark = AppEnvironment.bookmark(for: url)
        probeTask?.cancel()
        probeTask = Task {
            do {
                var video = try await AppEnvironment.probeSource(url, bookmark: bookmark)
                video.remoteOrigin = origin
                withExtendedLifetime(access) {}
                try Task.checkCancellation()
                navigation.replaceDraft { $0.setSource(video) }
            } catch MediaError.unsupportedFormat {
                alert = .unsupportedVideo
            } catch is CancellationError {
                return
            } catch {
                alert = UserMessage(error)
            }
        }
    }

    /// A blocked form isn't submitted: its button is off and says why.
    private func submit(isDraft: Bool) {
        let submitting = submitting
        submitting.run {
            await loader.refreshCommitted(environment, unit: spendCap?.unit ?? .usd)
            if spendCap != nil, let error = loader.spendError {
                alert = UserMessage(title: String(localized: "Can't read today's spending"), message: error)
                return
            }
            // A submit right after an edit decides on the form's own price, not on none.
            await loader.loadEstimates(estimateRequest, environment: environment, debounce: false)
            let form = navigation.createDraft
            let batchID = form.isBatch ? UUID() : nil
            await submitting.handle(form.submitDecision(isDraft: isDraft, in: context), blocked: { _ in }) {
                await enqueue($0, batchID: batchID, overCapApproved: $1)
            }
        }
    }

    /// One job per range or batch entry, in order; a failure stops the rest and leaves the queued ones running.
    /// Create stays on screen: the pipeline's toast says what was queued and leads to the Queue.
    /// - Parameters:
    ///   - batchID: shared by the jobs of a batch, so the queue and the library group them.
    ///   - overCapApproved: the user confirmed going over today's cap.
    private func enqueue(_ specs: [JobSpec], batchID: UUID?, overCapApproved: Bool = false) async {
        let parentID = navigation.createDraft.parentID
        if let error = await pipeline.enqueue(
            specs, parentID: parentID, batchID: batchID, overCapApproved: overCapApproved)
        {
            alert = error
        }
        await loader.refreshCommitted(environment, unit: spendCap?.unit ?? .usd)
    }

    private var pipeline: SubmitPipeline {
        SubmitPipeline(environment: environment, connection: connection)
    }
}

extension CreateView {
    private var spendCap: SpendCap? {
        _ = (capEnabled, capUSD, creditCapEnabled, capCredits)
        return environment.spendCap(for: connection.state.kind)
    }

    /// One batch character from picked or dropped images; says so when the batch is full or images didn't fit.
    fileprivate func addCharacter(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        alert = navigation.createDraft.addCharacterSet(ReferencesSection.references(urls)) ?? alert
    }

    /// Opens the Paste URL… field, filled with the clipboard's link if it holds one.
    fileprivate func askForLink(_ kind: MediaLink.Kind) {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        linkText = (try? MediaLink.parse(text))?.absoluteString ?? ""
        linkEntry = kind
    }

    fileprivate func downloadTypedLink(as kind: MediaLink.Kind) {
        do {
            downloadLink(try MediaLink.parse(linkText), expected: kind)
        } catch {
            alert = UserMessage(error)
        }
    }

    /// Downloads `link`, then takes the file like a dropped one: a video becomes the source, an image a reference.
    /// The file remembers the link, so a job that sends it whole can pass the link instead of uploading it.
    fileprivate func downloadLink(_ link: URL, expected: MediaLink.Kind?) {
        linkTask?.cancel()
        let download = LinkDownload(link: link, expected: expected)
        linkDownload = download
        linkTask = Task {
            defer {
                if linkDownload?.id == download.id { linkDownload = nil }
            }
            do {
                let throttle = ProgressThrottle()
                let media = try await environment.downloadLink(link, expected: expected) { fraction in
                    guard throttle.admits(fraction) else { return }
                    Task { @MainActor in showLinkProgress(fraction, of: download.id) }
                }
                try Task.checkCancellation()
                switch media.kind {
                case .video:
                    importSource(media.fileURL, origin: media.origin)
                case .image:
                    let image = LocalImage(
                        fileURL: media.fileURL, bookmark: AppEnvironment.bookmark(for: media.fileURL),
                        remoteOrigin: media.origin)
                    alert = navigation.createDraft.addOpenedReferences([image]) ?? alert
                }
            } catch is CancellationError {
                return
            } catch {
                alert = UserMessage(error)
            }
        }
    }

    /// Only reports that change the whole percent get here (`ProgressThrottle`); a late one of an earlier link is
    /// dropped.
    fileprivate func showLinkProgress(_ fraction: Double?, of id: UUID) {
        guard var current = linkDownload, current.id == id else { return }
        current.fraction = fraction
        linkDownload = current
    }

    fileprivate func cancelLinkDownload() {
        linkTask?.cancel()
        linkTask = nil
        linkDownload = nil
    }

    /// The video form with its stage.
    fileprivate func videoSide(_ form: Binding<CreateForm>) -> some View {
        HStack(spacing: Theme.Spacing.large) {
            panel(form)
                .alert(
                    linkEntry.map(LinkDownload.prompt(for:)) ?? "",
                    isPresented: Binding(isPresenting: $linkEntry), presenting: linkEntry
                ) { kind in
                    TextField(LinkDownload.placeholder, text: $linkText)
                    Button("Download") { downloadTypedLink(as: kind) }
                    Button("Cancel", role: .cancel) {}
                } message: { _ in
                    Text(LinkDownload.explanation)
                }
                // Gives up to 60 pt to the stage at the minimum window, where the Motion Library needs it most.
                .frame(minWidth: 320, idealWidth: 380, maxWidth: 380)
            CreateStage(
                form: form, connection: context.connection.kind, library: library,
                downloadingClip: downloadingClip,
                onImportSource: { importSource($0) }, onPickSource: { pick(.source) },
                onPickClip: { useClip($0) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background { MakeVideoHost(takesFrames: context.unavailableReason(for: .seedanceFrames) == nil) }
    }

    fileprivate func panel(_ form: Binding<CreateForm>) -> some View {
        CreatePanel(
            form: form, context: context, catalog: loader.catalog, isSubmitting: submitting.isBusy,
            onImportSource: { importSource($0) }, onPick: { pick($0) },
            onAddCharacter: { addCharacter($0) },
            onRefreshPresets: { Task { await loader.refreshPresets(environment) } },
            onSubmit: { submit(isDraft: $0) },
            onBrowseUploads: uploads == nil ? nil : { isBrowsingUploads = true },
            linkDownload: linkDownload,
            onPasteLink: { askForLink($0) },
            onCancelLink: { cancelLinkDownload() },
            generation: referenceGeneration,
            characterSaving: environment.characterSaving(elements, into: navigation)
        )
        .background { referenceGenerationHost }
    }

    /// Generate…'s loads, kept off `body`'s modifier chain so it type-checks in time. Behind the header, so both
    /// sides share them.
    fileprivate var referenceGenerationLoads: some View {
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
    fileprivate var referenceGenerationHost: some View {
        Color.clear
            .sheet(isPresented: $isGeneratingReferences) {
                let form = navigation.createDraft
                GenerateReferenceSheet(
                    source: form.source?.pixelSize, mode: form.mode, room: form.referenceRoom,
                    adding: addingGenerated, onAdd: { await addGenerated($0) })
            }
    }

    /// Generate… for References; `nil` while disconnected.
    fileprivate var referenceGeneration: ReferenceGeneration? {
        guard environment.imageProvider != nil else { return nil }
        return ReferenceGeneration(
            disabledReason: environment.referenceGenerationBlocker, onOpen: { isGeneratingReferences = true })
    }

    /// Downloads a generated image and adds it like an opened file; the message says why it wasn't added.
    fileprivate func addGenerated(_ image: GeneratedImage) async -> UserMessage? {
        guard addingGenerated.insert(image.id).inserted else { return nil }
        defer { addingGenerated.remove(image.id) }
        return await environment.addGenerated(image, to: navigation)
    }

    /// Downloads a Motion Library clip, then imports it like a picked file.
    fileprivate func useClip(_ preset: MotionPreset) {
        guard downloadingClip == nil else { return }
        downloadingClip = preset.id
        Task {
            defer { downloadingClip = nil }
            do {
                importSource(try await environment.downloadMotionClip(preset))
            } catch {
                alert = UserMessage(
                    title: String(localized: "Can't download the clip"),
                    message: String(localized: "Check your connection and try again."))
            }
        }
    }

    /// The submit bar's main button for File › Generate (⌘↩): the video submit, or the Image side's Generate.
    fileprivate var menuSubmit: CreateSubmit {
        if navigation.createKind == .image {
            let generator = environment.referenceGenerator
            return CreateSubmit(
                title: String(localized: "Generate"), isEnabled: imageController.canGenerate(generator)
            ) {
                imageController.generate(environment: environment)
            }
        }
        let primary = navigation.createDraft.primarySubmit(in: context, isSubmitting: submitting.isBusy)
        return CreateSubmit(title: primary.title, isEnabled: primary.isEnabled) { submit(isDraft: primary.isDraft) }
    }

    /// Takes the clipboard the way opened files are taken (bookmarks, the source probe, the reference limit);
    /// image data, such as a screenshot, is saved to a file first, and an `https:` link is downloaded first.
    fileprivate func paste() {
        let pasteboard = NSPasteboard.general
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        let links = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        let input = PastedInput(
            fileURLs: files as? [URL] ?? [], hasImage: NSImage.canInit(with: pasteboard), links: links,
            text: pasteboard.string(forType: .string))
        switch input {
        case .link(let link)?:
            downloadLink(link, expected: nil)
        case .files(let urls)?:
            navigation.open(urls)
        case .image?:
            do {
                navigation.open([try environment.savePastedImage(from: pasteboard)])
            } catch {
                alert = UserMessage(
                    title: String(localized: "Can't paste the image"), message: error.localizedDescription)
            }
        case nil:
            NSSound.beep()
        }
    }
}
