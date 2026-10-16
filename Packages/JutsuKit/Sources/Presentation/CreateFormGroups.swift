import Foundation
import JutsuCore

// Groups of `CreateForm`'s stored properties that change together. Each is saved under the keys its fields had in
// the form before, so a saved draft keeps one flat object (`CreateForm+Codable`).

/// Options only some models take, each `nil` until the user picks one; the jobs send them only on a model that
/// declares them. Optional, so a draft saved before one existed still decodes.
struct ModelPicks: Sendable, Hashable, Codable {
    /// Seedance's bitrate; until picked none is sent and the server's default applies.
    var bitrate: SeedanceBitrate?
    /// Kling's character orientation.
    var orientation: CharacterOrientation?
    /// Cinema Studio's creative controls, `nil` while none is set.
    var cinema: CinemaControls?
    /// Variants of each job (`CreateForm.variants`).
    var variants: Int?

    enum CodingKeys: String, CodingKey {
        case bitrate = "seedanceBitrate"
        case orientation = "klingOrientation"
        case cinema = "cinemaPicks"
        case variants = "variantCount"
    }
}

/// Seedance's start and end frames, for a clip made without a source (`CreateForm.usesFrames`).
struct FramePair: Sendable, Hashable, Codable {
    /// The image the clip starts on.
    var start: LocalImage?
    /// The image the clip ends on.
    var end: LocalImage?

    enum CodingKeys: String, CodingKey {
        case start = "startFrame"
        case end = "endFrame"
    }

    /// The first two of `images`, as a job made from frames lists them.
    init(_ images: [LocalImage] = []) {
        start = images.first
        end = images.dropFirst().first
    }

    subscript(slot: FrameSlot) -> LocalImage? {
        get {
            switch slot {
            case .start: start
            case .end: end
            }
        }
        set {
            switch slot {
            case .start: start = newValue
            case .end: end = newValue
            }
        }
    }

    /// The start frame, then the end frame.
    var images: [LocalImage] { [start, end].compactMap(\.self) }

    var isEmpty: Bool { start == nil && end == nil }
}

/// One range rendered once per style (restyle) or per character set (motion transfer, object swap): the batch's
/// entries and the character sets already published as elements.
struct CreateBatch: Sendable, Hashable, Codable {
    var isOn = false
    /// Restyle: the styles in the order picked.
    var presetIDs: [UUID] = []
    /// Motion transfer and object swap: one set of reference images per character.
    var characterSets: [[LocalImage]] = []
    /// Character sets published as elements ("Save to Higgsfield…"), by their images' file URLs (`key(of:)`), so a
    /// set isn't published twice. Optional so a draft saved before it still decodes.
    var savedSets: [[URL]: SavedElement]?

    enum CodingKeys: String, CodingKey {
        case isOn = "isBatch"
        case presetIDs = "batchPresetIDs"
        case characterSets
        case savedSets = "savedCharacterSets"
    }

    /// The jobs the batch makes in `mode`: one per style for restyle, one per character set otherwise.
    func count(in mode: Mode) -> Int { mode == .restyle ? presetIDs.count : characterSets.count }

    /// Adds the style, or takes it out. Returns `false` when `limit` styles are in and this one isn't, which leaves
    /// the styles as they were.
    mutating func togglePreset(_ id: UUID, limit: Int) -> Bool {
        if let index = presetIDs.firstIndex(of: id) {
            presetIDs.remove(at: index)
            return true
        }
        guard presetIDs.count < limit else { return false }
        presetIDs.append(id)
        return true
    }

    /// Removes a set; it stays published only while an equal set is still in the batch.
    mutating func removeCharacterSet(at index: Int) {
        guard characterSets.indices.contains(index) else { return }
        let removed = Self.key(of: characterSets.remove(at: index))
        if !characterSets.contains(where: { Self.key(of: $0) == removed }) { savedSets?[removed] = nil }
    }

    /// The element the set at `index` was published as on the account `owner`; `nil` when it wasn't.
    func savedElement(ofCharacterSet index: Int, owner: String?) -> SavedElement? {
        guard characterSets.indices.contains(index), let saved = savedSets?[Self.key(of: characterSets[index])],
            saved.owner == owner
        else { return nil }
        return saved
    }

    /// Records that the set of `images` was published as `element`.
    mutating func setSavedElement(_ element: SavedElement, forCharacterSet images: [LocalImage]) {
        savedSets = (savedSets ?? [:]).merging([Self.key(of: images): element]) { $1 }
    }

    /// The character sets with their files reopened by `reopened`, which returns `nil` for a file that can't be read
    /// any more. A set that lost every file is dropped; one that lost some is no longer the one published.
    func reopeningSets(_ reopened: (LocalImage) -> LocalImage?) -> CreateBatch {
        var batch = self
        var saved: [[URL]: SavedElement] = [:]
        batch.characterSets = characterSets.compactMap { images in
            let reopenedSet = images.compactMap(reopened)
            guard !reopenedSet.isEmpty else { return nil }
            if reopenedSet.count == images.count, let element = savedSets?[Self.key(of: images)] {
                saved[Self.key(of: reopenedSet)] = element
            }
            return reopenedSet
        }
        batch.savedSets = savedSets == nil ? nil : saved
        return batch
    }

    /// A set is known by its files, which stay the same while it is in the form.
    static func key(of images: [LocalImage]) -> [URL] { images.map(\.fileURL) }
}
