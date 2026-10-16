import Foundation
import JutsuCore

// MARK: Audio

extension CreateForm {
    /// A model with `generatedAudio` (Seedance) can make a soundtrack for a clip from a source too, instead of the
    /// source's; Extend's new part always gets one (`generatesAudio`).
    public var offersGeneratedAudio: Bool {
        selectedModel.declares(.generatedAudio) && source != nil && mode != .extend
    }

    /// The Audio picker's entries when the sound comes from the source.
    public var audioChoices: [AudioOption] {
        offersGeneratedAudio ? [.original, .mute, .fadeOut, .generated] : [.original, .mute, .fadeOut]
    }

    /// `audio` as the jobs take it: a soundtrack the model can't make here is the source's.
    var jobAudio: AudioOption {
        audio == .generated && !offersGeneratedAudio ? .original : audio
    }

    /// "From the source", or the model when it makes the sound.
    public var audioDetail: String {
        jobAudio == .generated
            ? String(localized: "Made by \(selectedModel.title)", bundle: .module)
            : String(localized: "From the source", bundle: .module)
    }
}

// MARK: Seedance bitrate

extension CreateForm {
    /// Seedance's Quality picker, under Resolution.
    public var showsBitrate: Bool { selectedModel.declares(.bitrate) }

    /// The bitrate picked, or until then what the connection's server uses when none is sent: Standard on the
    /// account (`models_explore`'s `bitrate_mode` default), High with an API key (the REST schemas' default).
    public func bitrate(on connection: ProviderKind?) -> SeedanceBitrate {
        picks.bitrate ?? (connection == .account ? .standard : .high)
    }

    public mutating func setBitrate(_ bitrate: SeedanceBitrate) {
        picks.bitrate = bitrate
    }

    /// Only a picked bitrate is sent; otherwise each server applies its own default, the one `bitrate(on:)` shows.
    var jobBitrate: SeedanceBitrate? { showsBitrate ? picks.bitrate : nil }
}

// MARK: Kling orientation

extension CreateForm {
    /// Kling's "Character faces" picker.
    public var showsCharacterOrientation: Bool { selectedModel.declares(.characterOrientation) }

    /// As in the video until picked: the server's default.
    public var characterOrientation: CharacterOrientation {
        get { picks.orientation ?? .video }
        set { picks.orientation = newValue }
    }

    var jobCharacterOrientation: CharacterOrientation? { showsCharacterOrientation ? characterOrientation : nil }
}

// MARK: Cinema Studio controls

extension CreateForm {
    /// Cinema Studio's camera, lens, genre, era and the rest, under the model picker.
    public var showsCinemaControls: Bool { selectedModel.declares(.cinemaControls) }

    /// None set until picked: the director picks each one left out.
    public var cinemaControls: CinemaControls {
        get { picks.cinema ?? CinemaControls() }
        set { picks.cinema = newValue.isEmpty ? nil : newValue }
    }

    /// One control's value; `nil` leaves it to the director.
    public subscript(cinema control: CinemaControl) -> String? {
        get { cinemaControls[control] }
        set { cinemaControls[control] = newValue }
    }

    /// "2 set", or `nil` with none, for the closed controls' row.
    public var cinemaControlsSummary: String? {
        let count = cinemaControls.count
        return count == 0 ? nil : String(localized: "\(count) set", bundle: .module)
    }

    var jobCinemaControls: CinemaControls { showsCinemaControls ? cinemaControls : CinemaControls() }
}

// MARK: Start and end frames

/// One of Seedance's frame slots.
public enum FrameSlot: Sendable, Hashable, CaseIterable {
    case start
    case end

    public var title: String {
        switch self {
        case .start: String(localized: "Start frame", bundle: .module)
        case .end: String(localized: "End frame", bundle: .module)
        }
    }
}

extension CreateForm {
    /// A model with `frames` (Seedance) can start and end on given images without a source (`image-to-video`); a
    /// batch compares references instead.
    public var showsFrames: Bool {
        selectedModel.declares(.frames) && isWithoutSource && !isBatch
    }

    /// A frame is filled, so the jobs run from the frames and the references wait.
    public var usesFrames: Bool { showsFrames && !frames.isEmpty }

    public func frame(_ slot: FrameSlot) -> LocalImage? { frames[slot] }

    /// Fills or clears (`nil`) one slot.
    public mutating func setFrame(_ image: LocalImage?, for slot: FrameSlot) {
        frames[slot] = image
    }

    /// Why the references are off while frames are used; `nil` otherwise.
    public var referencesDisabledReason: String? {
        guard usesFrames else { return nil }
        return String(
            localized: "Seedance starts from the frames, so references aren't used. Clear both frames to use them.",
            bundle: .module)
    }

    /// The frames need a start; an end alone can't run.
    var framesBlocker: String? {
        guard usesFrames, frames.start == nil else { return nil }
        return String(localized: "Add a start frame, or clear the end frame", bundle: .module)
    }
}

extension CreateContext {
    /// `unavailableReason(for:)` short enough for the tooltip of the control that sets `parameter`.
    public func unavailableHint(for parameter: ModelParameter) -> String? {
        guard unavailableReason(for: parameter) != nil else { return nil }
        let isAccount = connection.kind == .account
        if parameter == .klingVideoBackground {
            return isAccount
                ? String(localized: "Not available for this account", bundle: .module)
                : String(localized: "Only on a Higgsfield account", bundle: .module)
        }
        return isAccount
            ? String(localized: "Only with an API key", bundle: .module)
            : String(localized: "Not available with this API key", bundle: .module)
    }

    /// Why this connection can't send `parameter`; `nil` when it can, or while the capabilities are unknown.
    public func unavailableReason(for parameter: ModelParameter) -> String? {
        guard let capabilities, !capabilities.parameters.contains(parameter) else { return nil }
        // The connection decides only the wording: which one offers the parameter.
        guard connection.kind == .account else {
            return parameter == .klingVideoBackground
                ? String(
                    localized: "Kling keeps the video's background only on a Higgsfield account, not with an API key",
                    bundle: .module)
                : String(localized: "Not available with this API key", bundle: .module)
        }
        return switch parameter {
        case .seedanceBitrate:
            String(
                localized: "Seedance's bitrate is set with an API key; the account doesn't offer it yet",
                bundle: .module)
        case .seedanceFrames:
            String(
                localized: "Seedance's start and end frames run with an API key; the account doesn't offer them yet",
                bundle: .module)
        case .klingOriginalSound:
            String(
                localized: "Kling keeps the source's sound on the server only with an API key, not on the account",
                bundle: .module)
        case .klingOrientation:
            String(
                localized: "Kling's character orientation is set only with an API key, not on the account",
                bundle: .module)
        case .cinemaControls:
            String(
                localized: "Cinema Studio's creative controls are set only with an API key, not on the account",
                bundle: .module)
        case .klingVideoBackground:
            String(localized: "Not available for this account", bundle: .module)
        }
    }
}
