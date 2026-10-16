import Foundation
import JutsuCore

/// The batch matrix: one range × several styles or character sets, queued as one group of jobs.
extension CreateForm {
    /// A batch compares at least two results and runs at most twelve jobs, so one click can't queue
    /// an unbounded bill.
    public static let batchSizes = 2...12

    /// One range rendered once per style (restyle) or per character set (motion transfer, object swap), as one
    /// batch of jobs. Turning it on starts the list from the single preset or image set the form has.
    public var isBatch: Bool {
        get { batch.isOn }
        set {
            let wasOn = batch.isOn
            batch.isOn = newValue
            guard newValue, !wasOn else { return }
            if batch.presetIDs.isEmpty, let presetID { batch.presetIDs = [presetID] }
            if batch.characterSets.isEmpty, mode != .restyle, !references.isEmpty { batch.characterSets = [references] }
        }
    }

    /// Restyle batch: the styles in the order picked.
    public var batchPresetIDs: [UUID] { batch.presetIDs }

    /// Motion transfer and object swap batch: one set of reference images per character.
    public var characterSets: [[LocalImage]] { batch.characterSets }

    /// How many jobs the batch makes: one per style for restyle, one per character set otherwise.
    public var batchCount: Int { batch.count(in: mode) }

    /// "3 / 12".
    public var batchCountText: String { "\(batchCount) / \(Self.batchSizes.upperBound)" }

    public var canAddBatchVariant: Bool { batchCount < Self.batchSizes.upperBound }

    /// Next to the batch switch.
    public var batchHint: String {
        let most = Self.batchSizes.upperBound
        return mode == .restyle
            ? String(localized: "One range × up to \(most) styles, side by side", bundle: .module)
            : String(localized: "One range × up to \(most) characters, side by side", bundle: .module)
    }

    /// "A batch takes up to 12 styles" or "… characters".
    var batchFullText: String {
        let most = Self.batchSizes.upperBound
        return mode == .restyle
            ? String(localized: "A batch takes up to \(most) styles", bundle: .module)
            : String(localized: "A batch takes up to \(most) characters", bundle: .module)
    }

    /// Shown once the batch is full, so a style or set that doesn't get added isn't a mystery.
    public var batchCapNotice: String? {
        guard isBatch, !canAddBatchVariant else { return nil }
        let most = Self.batchSizes.upperBound
        return mode == .restyle
            ? String(localized: "A batch takes up to \(most) styles. Remove one to add another.", bundle: .module)
            : String(localized: "A batch takes up to \(most) characters. Remove one to add another.", bundle: .module)
    }

    /// "Draft 480p × 4" in a batch, else "Draft 480p".
    public var draftButtonTitle: String { isBatch ? "\(draftTitle) × \(batchCount)" : draftTitle }

    /// "Generate × 4" in a batch, else "Generate".
    public var generateButtonTitle: String {
        isBatch
            ? String(localized: "Generate × \(batchCount)", bundle: .module)
            : String(localized: "Generate", bundle: .module)
    }

    /// Adds the style to a restyle batch, or takes it out. Returns `false` when the batch is full and the style
    /// isn't in it, which leaves the batch as it was.
    @discardableResult
    public mutating func toggleBatchPreset(_ id: UUID) -> Bool {
        batch.togglePreset(id, limit: Self.batchSizes.upperBound)
    }

    /// Adds one character from `images`, in order and without repeats, up to the mode's image limit.
    /// Returns what the user has to know: the batch is full, or some images didn't fit the set.
    @discardableResult
    public mutating func addCharacterSet(_ images: [LocalImage]) -> UserMessage? {
        var seen = Set<URL>()
        let distinct = images.filter { seen.insert($0.fileURL).inserted }
        guard !distinct.isEmpty else { return nil }
        guard canAddBatchVariant else {
            return UserMessage(
                title: batchFullText, message: String(localized: "Remove a character to add another.", bundle: .module))
        }
        let limit = limits.referenceImages.upperBound
        batch.characterSets.append(Array(distinct.prefix(limit)))
        let left = distinct.count - limit
        guard left > 0 else { return nil }
        return UserMessage(
            title: String(localized: "\(left) images weren't added", bundle: .module),
            message: limit == 1
                ? String(localized: "Each character takes one reference image.", bundle: .module)
                : String(localized: "Each character takes up to \(limit) reference images.", bundle: .module))
    }

    public mutating func removeCharacterSet(at index: Int) {
        batch.removeCharacterSet(at: index)
    }

    /// The element the set at `index` was published as on the account `owner`; `nil` when it wasn't.
    public func savedElement(ofCharacterSet index: Int, owner: String?) -> SavedElement? {
        batch.savedElement(ofCharacterSet: index, owner: owner)
    }

    /// Records that the set of `images` was published as `element`.
    public mutating func setSavedElement(_ element: SavedElement, forCharacterSet images: [LocalImage]) {
        batch.setSavedElement(element, forCharacterSet: images)
    }

    /// `base` once per style or character set, in the order they were added.
    func batchSpecs(from base: JobSpec) -> [JobSpec] {
        if mode == .restyle {
            return batchPresetIDs.map { id in
                var spec = base
                spec.presetID = id
                return spec
            }
        }
        return characterSets.map { images in
            var spec = base
            spec.references = images
            // The media IDs held for an account source belong to its own images, not to another character's.
            spec.remoteInputs = reusableInputs(for: images)
            return spec
        }
    }

    /// Why the batch can't be queued, before each job's own checks; `nil` when it can or isn't a batch.
    var batchBlocker: String? {
        guard isBatch else { return nil }
        if hasSeveralRanges { return String(localized: "A batch uses one range, remove the others", bundle: .module) }
        let least = Self.batchSizes.lowerBound
        if batchCount < least {
            return mode == .restyle
                ? String(localized: "Pick at least \(least) styles", bundle: .module)
                : String(localized: "Add at least \(least) characters", bundle: .module)
        }
        if batchCount > Self.batchSizes.upperBound { return batchFullText }
        return nil
    }

    /// The first job's validation problem as the cost line shows it; a character set's problem names the set.
    func validationBlocker(_ specs: [JobSpec]) -> String? {
        for (index, spec) in specs.enumerated() {
            guard let issue = Validation.check(spec, constraints: constraints ?? .builtIn).first else { continue }
            let message = text(for: issue)
            return isBatch && mode != .restyle
                ? String(localized: "Character \(index + 1): \(message)", bundle: .module) : message
        }
        return nil
    }
}
