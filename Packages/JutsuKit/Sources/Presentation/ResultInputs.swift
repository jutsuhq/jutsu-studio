import Foundation
import JutsuCore

/// A file that went into a result, to save back to the Mac: the source video or a reference image. The copy
/// on this Mac is used while it is there; otherwise the one Higgsfield keeps is downloaded.
public struct InputFile: Sendable, Hashable, Identifiable {
    public enum Role: Sendable, Hashable {
        case source
        /// 1-based, in the order the job sent them.
        case reference(Int)
    }

    public var role: Role
    /// The picked file and its security-scoped bookmark; `nil` when the input only exists on Higgsfield.
    public var local: LocalImage?
    /// Where Higgsfield keeps the uploaded file; `nil` for a job that never uploaded it.
    public var remote: URL?

    public var id: Role { role }

    public var title: String {
        switch role {
        case .source: String(localized: "Source video", bundle: .module)
        case .reference(let number): String(localized: "Reference \(number)", bundle: .module)
        }
    }

    /// "rooftop – Source.mp4", "rooftop – Reference 2.png". The extension comes from the file, else the kind.
    public func fileName(base: String) -> String {
        let label =
            switch role {
            case .source: String(localized: "Source", bundle: .module)
            case .reference(let number): String(localized: "Reference \(number)", bundle: .module)
            }
        let fallback = role == .source ? "mp4" : "jpg"
        let ext = [local?.fileURL, remote].compactMap { $0?.pathExtension }.first { !$0.isEmpty } ?? fallback
        return "\(Self.fileSafe(base)) – \(label).\(ext.lowercased())"
    }

    /// `name` without the characters a file name can't hold, and without leading dots, which would hide the file;
    /// "Result" when nothing is left.
    static func fileSafe(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = String(cleaned.drop { $0 == "." || $0.isWhitespace })
        return visible.isEmpty ? "Result" : visible
    }

    /// The source and every reference of the item, in the job's order; inputs with no file anywhere are left out.
    public static func all(in item: LibraryItemModel) -> [InputFile] {
        let spec = item.spec
        let uploaded = item.job.inputs ?? item.historyItem?.inputs ?? spec.remoteInputs
        let source = spec.source.map {
            InputFile(
                role: .source, file: LocalImage(fileURL: $0.fileURL, bookmark: $0.bookmark),
                uploaded: uploaded?.video?.url)
        }
        let references = spec.references.enumerated().map { index, reference in
            InputFile(
                role: .reference(index + 1), file: reference,
                uploaded: uploaded.flatMap { $0.images.indices.contains(index) ? $0.images[index].url : nil })
        }
        return ((source.map { [$0] } ?? []) + references).filter { $0.local != nil || $0.remote != nil }
    }

    /// A file URL is the local copy; a web URL means the spec itself points at Higgsfield's copy.
    private init(role: Role, file: LocalImage, uploaded: URL?) {
        self.role = role
        if file.fileURL.isFileURL {
            local = file
            remote = uploaded
        } else {
            local = nil
            remote = uploaded ?? file.fileURL
        }
    }

    public init(role: Role, local: LocalImage?, remote: URL?) {
        self.role = role
        self.local = local
        self.remote = remote
    }
}
