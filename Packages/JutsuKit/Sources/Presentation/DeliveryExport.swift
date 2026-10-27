import Foundation
import JutsuCore

/// Runs a delivery's files (`DeliveryPlan`) one after another and says how each one went. A file that fails is
/// noted and the run goes on, so Retry Failed later writes only those; an item whose file isn't on this Mac is
/// skipped. A canceled run stops and notes nothing for the files it didn't finish.
@MainActor
public enum DeliveryRun {
    public enum State: Sendable, Hashable {
        case waiting
        case running
        case done
        case failed(String)
        case skipped(String)
    }

    /// - Parameters:
    ///   - export: writes one file; `DeliverySetError.sourceUnavailable` skips it, any other error fails it.
    ///   - report: each task's state as it changes, by `DeliveryTask.id`.
    /// - Returns: the result of every task that finished, in order, for `DeliverySet.record`.
    public static func run(
        _ tasks: [DeliveryTask], export: (DeliveryTask) async throws -> Void,
        report: (String, State) -> Void = { _, _ in }
    ) async -> [DeliveryResult] {
        for task in tasks { report(task.id, .waiting) }
        var results: [DeliveryResult] = []
        for task in tasks {
            if Task.isCancelled { break }
            report(task.id, .running)
            do {
                try await export(task)
                results.append(task.result(.done))
                report(task.id, .done)
            } catch is CancellationError {
                break
            } catch DeliverySetError.noSubtitles {
                let message = DeliveryContent.noSubtitlesMessage
                results.append(task.result(.failed, message: message))
                report(task.id, .failed(message))
            } catch DeliverySetError.sourceUnavailable {
                let message = DeliveryContent.unavailableMessage
                results.append(task.result(.skipped, message: message))
                report(task.id, .skipped(message))
            } catch {
                let message = error.localizedDescription
                results.append(task.result(.failed, message: message))
                report(task.id, .failed(message))
            }
        }
        return results
    }
}

/// How many of a set's files are done, failed or skipped.
public struct DeliveryCounts: Sendable, Hashable {
    public var done = 0
    public var failed = 0
    public var skipped = 0

    public init(_ set: DeliverySet) {
        for result in set.results {
            switch result.status {
            case .done: done += 1
            case .failed: failed += 1
            case .skipped: skipped += 1
            }
        }
    }
}

/// Texts of the delivery sets sheet.
public enum DeliveryContent {
    public static let title = String(localized: "Delivery Sets", bundle: .module)
    public static let newSetTitle = String(localized: "New Delivery Set", bundle: .module)
    public static let unavailableMessage = String(
        localized: "The file isn't on this Mac. Download it to the library or connect its drive.", bundle: .module)
    public static let noSubtitlesMessage = String(
        localized:
            "This version has no subtitles. Make them with Subtitles… on its page, or turn subtitles off for this output.",
        bundle: .module)
    public static let frozenMessage = String(
        localized: "This set has been exported, so its versions stay as they are. Start a new set from it instead.",
        bundle: .module)

    /// "Delivery 15 Oct 2026".
    public static func defaultName(at date: Date) -> String {
        String(localized: "Delivery \(date.formatted(date: .abbreviated, time: .omitted))", bundle: .module)
    }

    /// "Delivery 15 Oct 2026 – next round": the set started from the one called `name`.
    public static func nextRoundName(after name: String) -> String {
        String(localized: "\(name) – next round", bundle: .module)
    }

    /// "Not exported", or "Exported 15 Oct 2026 at 10:41 to Client".
    public static func status(of set: DeliverySet) -> String {
        switch set.status {
        case .notExported:
            String(localized: "Not exported", bundle: .module)
        case .exported(let date, let folder):
            String(
                localized:
                    "Exported \(date.formatted(date: .abbreviated, time: .shortened)) to \(folder.lastPathComponent)",
                bundle: .module)
        }
    }

    /// "12 done · 1 failed · 2 skipped", leaving out what is zero; `nil` before any export.
    public static func summary(_ counts: DeliveryCounts) -> String? {
        let parts = [
            counts.done > 0 ? String(localized: "\(counts.done) done", bundle: .module) : nil,
            counts.failed > 0 ? String(localized: "\(counts.failed) failed", bundle: .module) : nil,
            counts.skipped > 0 ? String(localized: "\(counts.skipped) skipped", bundle: .module) : nil,
        ].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "JPEG · 2048 px · 4:5 · sRGB", or "Editing H.264 · 9:16".
    public static func summary(of output: DeliveryOutput) -> String {
        var parts: [String]
        switch output.preset {
        case .image(let image):
            parts = [image.format.title]
            if let edge = image.longEdge { parts.append(String(localized: "\(edge) px", bundle: .module)) }
            parts.append(image.colorSpace.title)
        case .video(let video):
            parts = [video.title]
        }
        if let aspect = output.aspect { parts.insert(aspect.title, at: 1) }
        if output.kind == .video, let subtitles = output.subtitles { parts.append(subtitles.title) }
        return parts.joined(separator: " · ")
    }
}

extension DeliverySubtitles {
    /// "SRT + VTT", "Burn In".
    public var title: String {
        switch self {
        case .files: "SRT + VTT"
        case .burnIn: String(localized: "Burn In", bundle: .module)
        }
    }
}

extension ImageExportPreset.Format {
    public var title: String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC"
        }
    }
}

extension ImageExportPreset.ColorSpace {
    public var title: String {
        switch self {
        case .sRGB: "sRGB"
        case .displayP3: "Display P3"
        }
    }
}
