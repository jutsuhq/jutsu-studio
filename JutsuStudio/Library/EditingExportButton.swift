import AppKit
import JutsuCore
import MediaKit
import Observation
import Presentation
import SwiftUI
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "Library")

/// "Export for Editing…" in a result's top bar: a menu of editing presets, then a folder panel. While
/// the take exports it shows progress and a cancel button; the finished file is shown in Finder. A version with
/// subtitles can have them written as an `.srt` next to the take.
struct EditingExportButton: View {
    let item: LibraryItemModel
    /// The current version's, `nil` when it has none.
    var subtitles: Subtitles?

    @AppStorage(EditingExportContent.writesSidecarKey) private var writesSidecar = true
    @AppStorage(EditingExportContent.writesSubtitlesKey) private var writesSubtitles = true
    @State private var model = EditingExportModel()

    var body: some View {
        Group {
            if let progress = model.progress {
                HStack(spacing: 6) {
                    ProgressView(value: progress)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    Button("Cancel Export", systemImage: "xmark") { model.cancel() }
                        .buttonStyle(.iconAction)
                        .hoverHint("Cancel export")
                }
            } else {
                menu
            }
        }
        .alert(
            model.message?.title ?? "", isPresented: Binding(isPresenting: $model.message),
            presenting: model.message
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message.message)
        }
    }

    private var menu: some View {
        Menu {
            ForEach(ExportPreset.allCases, id: \.self) { preset in
                Button("\(preset.title) (\(preset.formatSummary))") { export(preset) }
            }
            Divider()
            Toggle(EditingExportContent.sidecarToggleTitle, isOn: $writesSidecar)
            if subtitles != nil {
                Toggle(EditingExportContent.subtitlesToggleTitle, isOn: $writesSubtitles)
            }
        } label: {
            Label(EditingExportContent.menuTitle, systemImage: "film.stack")
        }
        .menuStyle(.button)
        .buttonStyle(.iconAction)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(item.outputFile == nil)
        .hoverHint("Export for editing")
    }

    private func export(_ preset: ExportPreset) {
        guard item.outputFile != nil, let folder = chooseFolder() else { return }
        model.start(
            preset, item: item, to: folder, writesSidecar: writesSidecar,
            subtitles: writesSubtitles ? subtitles?.cues : nil)
    }

    private func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = EditingExportContent.folderPrompt
        panel.message = EditingExportContent.folderMessage
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// One export at a time. The encode runs off the main actor in `EditingExporter`.
@MainActor
@Observable
final class EditingExportModel {
    /// 0…1 while an export runs, `nil` otherwise.
    private(set) var progress: Double?
    var message: UserMessage?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// - Parameter subtitles: cues written as an `.srt` next to the take; `nil` for none.
    func start(
        _ preset: ExportPreset, item: LibraryItemModel, to folder: URL, writesSidecar: Bool,
        subtitles: [SubtitleCue]? = nil
    ) {
        guard task == nil, let result = item.outputFile else { return }
        progress = 0
        task = Task {
            defer {
                progress = nil
                task = nil
            }
            do {
                let video = try await run(
                    preset, item: item, result: result, folder: folder, writesSidecar: writesSidecar,
                    subtitles: subtitles)
                NSWorkspace.shared.activateFileViewerSelecting([video])
            } catch is CancellationError {
                return
            } catch {
                logger.error("Editing export failed: \(String(describing: error), privacy: .private)")
                message = Self.message(for: error)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// A progress hop that arrives after the export finished is dropped.
    private func report(_ value: Double) {
        if progress != nil { progress = value }
    }

    private func run(
        _ preset: ExportPreset, item: LibraryItemModel, result: URL, folder: URL, writesSidecar: Bool,
        subtitles: [SubtitleCue]?
    ) async throws -> URL {
        let isAccessing = folder.startAccessingSecurityScopedResource()
        defer {
            if isAccessing { folder.stopAccessingSecurityScopedResource() }
        }
        // Lowercased: APFS and HFS+ volumes are case-insensitive by default.
        let existing = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
        let taken = Set(existing.map { $0.lowercased() })
        let names = ExportNaming.names(for: item.spec, presetName: item.presetName, preset: preset) {
            taken.contains($0.lowercased())
        }
        let video = folder.appendingPathComponent(names.video)
        let sidecar = writesSidecar ? folder.appendingPathComponent(names.sidecar) : nil
        let throttle = ProgressThrottle()
        let sidecarError = try await Self.write(preset, item: item, result: result, to: video, sidecar: sidecar) {
            value in
            guard throttle.admits(value) else { return }
            Task { @MainActor in self.report(value) }
        }
        if let sidecarError {
            message = UserMessage(
                title: String(localized: "The JSON sidecar wasn't written"), message: sidecarError.localizedDescription)
        }
        if let subtitles {
            // Timed as the take is: the export keeps the result's timeline from its start.
            // Its name was free with the video's when they were picked.
            let srt = folder.appendingPathComponent(names.subtitles)
            do {
                try Data(SubtitleFormat.srt.text(of: subtitles).utf8).write(to: srt, options: .withoutOverwriting)
            } catch {
                logger.error("Can't write an export's subtitles: \(String(describing: error), privacy: .private)")
                message = UserMessage(
                    title: String(localized: "The subtitles weren't written"), message: error.localizedDescription)
            }
        }
        return video
    }

    /// Encodes the take to `video`, then writes its sidecar when one is asked for; neither replaces a file. The take
    /// is done either way, so a sidecar that can't be written is returned rather than thrown.
    static func write(
        _ preset: ExportPreset, item: LibraryItemModel, result: URL, to video: URL, sidecar: URL?,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> (any Error)? {
        try await EditingExporter.export(
            result, source: item.spec.source, preset: preset, to: video, progress: progress)
        guard let sidecar else { return nil }
        do {
            let content = ExportSidecar(
                job: item.job, presetName: item.presetName, exportPreset: preset, exportedAt: Date())
            try content.encoded().write(to: sidecar, options: .withoutOverwriting)
            return nil
        } catch {
            logger.error("Can't write an export sidecar: \(String(describing: error), privacy: .private)")
            return error
        }
    }

    private static func message(for error: any Error) -> UserMessage {
        switch error as? MediaError {
        case .exportFailed(let reason):
            EditingExportContent.failure(detail: reason)
        case .unsupportedFormat:
            EditingExportContent.failure(detail: String(localized: "AVFoundation can't read the result file."))
        default:
            EditingExportContent.failure(detail: error.localizedDescription)
        }
    }
}
