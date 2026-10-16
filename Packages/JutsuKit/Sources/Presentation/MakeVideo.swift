import Foundation
import JutsuCore

/// The part an image plays in a video made from it (Make Video): a frame the clip starts or ends on, or a reference
/// to draw from. Which ones a model takes comes from the catalog (`models.json`): the frames from its `frames`
/// control, a reference from its reference image limit.
public enum ImageRole: String, Sendable, Hashable, CaseIterable {
    case startFrame, endFrame, reference

    public var title: String {
        switch self {
        case .startFrame: FrameSlot.start.title
        case .endFrame: FrameSlot.end.title
        case .reference: String(localized: "Reference", bundle: .module)
        }
    }

    /// The role the catalog records for the image when the job is queued.
    public var materialRole: MaterialInput.Role {
        switch self {
        case .startFrame: .startFrame
        case .endFrame: .endFrame
        case .reference: .reference
        }
    }

    /// The roles `model` takes for an image in `mode`, in this order: start frame, end frame, reference. Frames go
    /// with a model that makes a clip from them without a source; a reference with one whose limit takes an image.
    public static func options(
        for model: VideoModel, mode: Mode, constraints: ModelConstraintTable = .builtIn
    ) -> [ImageRole] {
        var roles: [ImageRole] = []
        if model.declares(.frames) && model.makesClipsWithoutSource { roles += [.startFrame, .endFrame] }
        if model.limits(for: mode, constraints: constraints).referenceImages.upperBound > 0 { roles.append(.reference) }
        return roles
    }
}

/// One way Make Video can place the chosen images in Create: the role of each image, in the images' order.
public struct MakeVideoChoice: Sendable, Hashable, Identifiable {
    public var roles: [ImageRole]

    public var id: [ImageRole] { roles }

    public init(roles: [ImageRole]) {
        self.roles = roles
    }

    /// Frames replace the source video, which Create says with the Undo toast.
    public var usesFrames: Bool { roles.contains { $0 != .reference } }

    /// "Start frame", "Start and end frames", "3 references".
    public var title: String {
        if roles == [.startFrame, .endFrame] { return String(localized: "Start and end frames", bundle: .module) }
        if roles.count == 1, let role = roles.first { return role.title }
        return String(localized: "\(roles.count) references", bundle: .module)
    }
}

/// Images on their way from the Library to Create's video side, with the catalog versions they are; Create asks for
/// their role when more than one fits (`CreateForm.makeVideoChoices`).
public struct MakeVideoRequest: Sendable, Hashable, Identifiable {
    public let id: UUID
    /// In the order they were chosen; with two, the first is the start frame.
    public var images: [LocalImage]

    public init(images: [LocalImage], id: UUID = UUID()) {
        self.id = id
        self.images = images
    }
}

extension CreateForm {
    /// The ways the selected model can take `count` images: each role it takes for one, a start and an end frame or
    /// references for two, references for more. Empty when it takes none of them. `takesFrames` is false when the
    /// connection can't send frames (`ModelParameter.seedanceFrames`), so they aren't offered.
    public func makeVideoChoices(imageCount count: Int, takesFrames: Bool = true) -> [MakeVideoChoice] {
        let roles = ImageRole.options(for: selectedModel, mode: mode, constraints: constraints ?? .builtIn)
            .filter { takesFrames || $0 == .reference }
        switch count {
        case 1:
            return roles.map { MakeVideoChoice(roles: [$0]) }
        case 2:
            var choices: [MakeVideoChoice] = []
            if roles.contains(.startFrame) && roles.contains(.endFrame) {
                choices.append(MakeVideoChoice(roles: [.startFrame, .endFrame]))
            }
            if roles.contains(.reference) { choices.append(MakeVideoChoice(roles: [.reference, .reference])) }
            return choices
        default:
            guard count > 0, roles.contains(.reference) else { return [] }
            return [MakeVideoChoice(roles: Array(repeating: .reference, count: count))]
        }
    }

    /// Why Make Video can't place images on the selected model; shown when `makeVideoChoices` is empty.
    public var makeVideoUnavailable: UserMessage {
        UserMessage(
            title: String(localized: "Can't make a video from these images", bundle: .module),
            message: String(
                localized: "\(selectedModel.title) doesn't take them. Pick another model in Create and try again.",
                bundle: .module))
    }

    /// Places `images` as `choice` says. Frames start a clip without a source, so they take the Motion task and
    /// replace the source video; references stop the frames, which would leave them unused, and a character batch,
    /// which has none. Go through `NavigationModel.replaceDraft`, so what is replaced comes back with Undo. Returns
    /// what didn't fit, as opened files do.
    public mutating func makeVideo(from images: [LocalImage], as choice: MakeVideoChoice) -> UserMessage? {
        if choice.usesFrames {
            model = selectedModel
            if mode.isVideoOperation { mode = .motionTransfer }
            if source != nil { setSource(nil) }
            isBatch = false
            for (image, role) in zip(images, choice.roles) {
                switch role {
                case .startFrame: frames.start = image
                case .endFrame: frames.end = image
                case .reference: break
                }
            }
            return nil
        }
        if usesFrames { frames = FramePair() }
        if isBatch && mode != .restyle { isBatch = false }
        return addOpenedReferences(images)
    }
}

// MARK: Roles after a change of model

/// An image the jobs send, with the part it plays.
struct PlacedImage: Sendable, Hashable {
    var image: LocalImage
    var role: ImageRole
}

extension CreateForm {
    /// The images the jobs send and their roles: the frames while they are used, else the references.
    var placedImages: [PlacedImage] {
        guard !usesFrames else {
            return [
                frames.start.map { PlacedImage(image: $0, role: .startFrame) },
                frames.end.map { PlacedImage(image: $0, role: .endFrame) },
            ].compactMap(\.self)
        }
        return references.map { PlacedImage(image: $0, role: .reference) }
    }

    /// Every image the form holds, used or waiting: the frames and the references.
    private var heldImages: Set<URL> { Set((frames.images + references).map(\.fileURL)) }

    /// Runs `change` (another model, mode or task), then checks the images' roles again. Frames the selected model
    /// no longer takes become references, first, where there is room; a reference over its limit is cut as before.
    /// Returns what changed in a sentence, `nil` when nothing did. Go through `NavigationModel.replaceDraft`, so the
    /// images cut come back with Undo.
    public mutating func recheckingRoles(_ change: (inout CreateForm) -> Void) -> String? {
        let before = placedImages
        let held = heldImages
        let hadFrames = usesFrames
        change(&self)
        if hadFrames, !showsFrames, !selectedModel.declares(.frames) {
            let moved = frames.images
            frames = FramePair()
            references = Array(
                (moved + references.filter { image in !moved.contains { $0.fileURL == image.fileURL } })
                    .prefix(referenceLimits.upperBound))
        }
        let after = Dictionary(placedImages.map { ($0.image.fileURL, $0.role) }) { first, _ in first }
        let removed = held.subtracting(heldImages).count
        let becameReferences = before.contains { $0.role != .reference && after[$0.image.fileURL] == .reference }
        var lines: [String] = []
        let model = selectedModel.title
        if becameReferences {
            lines.append(
                String(
                    localized: "\(model) doesn't take start and end frames, so they are references now.",
                    bundle: .module))
        }
        if removed > 0 {
            let images = String(localized: "\(referenceLimits.upperBound) reference images", bundle: .module)
            let removedImages = String(localized: "\(removed) images were removed", bundle: .module)
            lines.append(String(localized: "\(model) takes up to \(images): \(removedImages).", bundle: .module))
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }
}
