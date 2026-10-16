import Foundation
import JutsuCore

extension TemplateKind {
    /// The Create switch label.
    public var title: String {
        switch self {
        case .video: String(localized: "Video", bundle: .module)
        case .image: String(localized: "Image", bundle: .module)
        }
    }

    /// Under the Create title; `nil` for video, which keeps the mode's own tagline.
    public var tagline: String? {
        switch self {
        case .video: nil
        case .image:
            String(
                localized: "Make still images from a prompt. Every image is saved to Library › Images.",
                bundle: .module)
        }
    }
}

/// The Image side of Create: what the non-modal image panel asks for. A snapshot of `ReferenceGenerator`'s form,
/// saved between launches beside the video draft (`CreateDraftStore`). The runs and their images live in
/// `ReferenceGenerator`; this is only the form.
public struct ImageDraft: Sendable, Hashable, Codable {
    public var prompt = ""
    /// `nil` until the models are known; then one the connection offers.
    public var modelID: String?
    /// The frame the user picked; `nil` follows the model default.
    public var chosenAspectRatio: String?
    public var count = 1
    /// The image to edit, for a model that takes one.
    public var inputImage: LocalImage?

    public init(
        prompt: String = "", modelID: String? = nil, chosenAspectRatio: String? = nil, count: Int = 1,
        inputImage: LocalImage? = nil
    ) {
        self.prompt = prompt
        self.modelID = modelID
        self.chosenAspectRatio = chosenAspectRatio
        self.count = count
        self.inputImage = inputImage
    }

    /// Something the user put into the form: a prompt or an image to edit. The model, frame and count alone
    /// restore as a fresh form.
    public var hasInputs: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || inputImage != nil
    }

    /// The local file the form points at; Clear Cache keeps it, as it may live in a folder it empties.
    public var localFiles: Set<URL> {
        Set([inputImage?.fileURL].compactMap(\.self).filter(\.isFileURL))
    }

    /// The draft with its file reopened by `reopen`, which returns where it is now or `nil` when it can't be
    /// read any more. Files on the account (not file URLs) are kept as they are.
    public func reopeningFiles(_ reopen: (LocalImage) -> LocalImage?) -> ImageDraft {
        var draft = self
        draft.inputImage = inputImage.flatMap { $0.fileURL.isFileURL ? reopen($0) : $0 }
        return draft
    }
}
