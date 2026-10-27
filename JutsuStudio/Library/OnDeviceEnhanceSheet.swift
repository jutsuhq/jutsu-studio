import JutsuCore
import MediaKit
import Presentation
import SwiftUI

/// What an Enhance run on this Mac is made from: an exact version of a library item, and its file.
struct OnDeviceTarget: Identifiable {
    enum Kind {
        case smoothMotion
        case upscaleVideo
        case upscaleImage
    }

    let id = UUID()
    let kind: Kind
    let source: MaterialReference
    let file: URL
    /// The item's title, under the sheet's.
    let title: String
}

/// The options of an Enhance run on this Mac, how long it takes and that it is free. Before an engine's first run it
/// asks to let macOS download its model, and nothing touches the model until then. Starting the run adds it to
/// `OnDeviceRuns`, which runs one at a time; the item's card shows how far it is.
struct OnDeviceEnhanceSheet: View {
    let target: OnDeviceTarget

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var motion = SmoothMotion.fps60
    /// The video's frame rate, size and length, read once; `nil` until then.
    @State private var probed: MediaInfo?
    /// The image's upright size, read from its header.
    @State private var imageSize: PixelSize?
    /// The image has an alpha channel, which the result won't keep.
    @State private var hasAlpha = false
    @State private var isUnreadable = false
    @State private var agreesToDownload = false

    private var action: OnDeviceAction {
        switch target.kind {
        case .smoothMotion: .smoothMotion(motion)
        case .upscaleVideo: .upscaleVideo
        case .upscaleImage: .upscaleImage
        }
    }

    private var size: PixelSize? {
        target.kind == .upscaleImage ? imageSize : probed?.pixelSize
    }

    private var needsConsent: Bool {
        environment.onDevice.needsConsent(action.engine)
    }

    private var offeredMotions: [SmoothMotion] {
        SmoothMotion.offered(sourceFrameRate: probed?.frameRate ?? 0)
    }

    /// The file is too large for the run, as read from the file itself.
    private var isTooLarge: Bool {
        guard let size else { return false }
        switch target.kind {
        case .smoothMotion: return false
        case .upscaleVideo: return !OnDeviceUpscale.offersVideo(size)
        case .upscaleImage: return !OnDeviceUpscale.offersImage(size)
        }
    }

    private var expectedTime: TimeInterval? {
        switch target.kind {
        case .smoothMotion:
            probed.map {
                OnDeviceEstimate.smoothMotion(duration: $0.duration, frameRate: $0.frameRate, pixelSize: $0.pixelSize)
            }
        case .upscaleVideo:
            probed.map {
                OnDeviceEstimate.upscaleVideo(duration: $0.duration, frameRate: $0.frameRate, pixelSize: $0.pixelSize)
            }
        case .upscaleImage:
            imageSize.map(OnDeviceEstimate.upscaleImage)
        }
    }

    private var canStart: Bool {
        environment.onDevice.supports(action.engine) && size != nil && !isTooLarge
            && (!needsConsent || agreesToDownload)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            VStack(alignment: .leading, spacing: 4) {
                Text(target.kind == .smoothMotion ? String(localized: "Smooth Motion") : OnDeviceText.upscaleTitle)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text(target.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            options
            if needsConsent { consent }
            notes
            actions
        }
        .padding(24)
        .frame(width: 440)
        .background(Theme.background)
        .task { await probe() }
    }

    @ViewBuilder private var options: some View {
        switch target.kind {
        case .smoothMotion:
            SectionLabel(title: "Motion")
            SegmentedControl(selection: $motion, options: offeredMotions.map { ($0, $0.title) })
            Text(motion.keepsAudio ? OnDeviceText.smoothMotionNote : OnDeviceText.slowMotionSound)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
        case .upscaleVideo, .upscaleImage:
            SectionLabel(title: "Size")
            if let size {
                Text(OnDeviceText.upscaleSizes(size))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
            }
            if target.kind == .upscaleVideo || isTooLarge {
                Text(sizeNote)
                    .font(.system(size: 12))
                    .foregroundStyle(isTooLarge ? Theme.warning : Theme.muted)
            }
            if hasAlpha, !isTooLarge {
                Text(OnDeviceText.opaqueResult)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warning)
            }
        }
    }

    private var sizeNote: String {
        switch (target.kind, isTooLarge) {
        case (.upscaleImage, _): OnDeviceText.tooLargeImage
        case (_, true): OnDeviceText.tooLargeVideo
        default: OnDeviceText.upscaleSound
        }
    }

    private var consent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(OnDeviceText.modelNotice)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(OnDeviceText.modelConsent, isOn: $agreesToDownload)
                .toggleStyle(.checkbox)
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(OnDeviceText.price)
            if let expectedTime {
                Text(OnDeviceText.expectedTime(expectedTime))
            } else if isUnreadable {
                Text("This file can't be read.").foregroundStyle(Theme.warning)
            }
            Text(OnDeviceText.versionNote)
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.muted)
    }

    private var actions: some View {
        HStack(spacing: Theme.Spacing.small) {
            Spacer(minLength: Theme.Spacing.small)
            Button("Cancel") { dismiss() }
                .buttonStyle(.secondaryAction)
                .keyboardShortcut(.cancelAction)
            Button {
                start()
            } label: {
                HStack(spacing: Theme.Spacing.small) {
                    Label(action.title, systemImage: "wand.and.rays")
                    PriceTag(text: String(localized: "Free"))
                }
            }
            .buttonStyle(.primaryAction)
            .keyboardShortcut(.defaultAction)
            .disabled(!canStart)
        }
    }

    private func start() {
        if needsConsent { environment.onDevice.agree(to: action.engine) }
        environment.startOnDevice(action, source: target.source, file: target.file)
        dismiss()
    }

    private func probe() async {
        if target.kind == .upscaleImage {
            imageSize = ImageThumbnail.size(at: target.file)
            hasAlpha = ImageThumbnail.hasAlpha(at: target.file)
            isUnreadable = imageSize == nil
            return
        }
        probed = try? await MediaProbe.probe(target.file)
        isUnreadable = probed == nil
        if !offeredMotions.contains(motion), let first = offeredMotions.first { motion = first }
    }
}

/// How far a run on this Mac is, an Enhance run or subtitles, over a library card.
struct OnDeviceRunBadge: View {
    let fraction: Double?
    let text: String

    init(run: OnDeviceRuns.Run) {
        fraction = run.state.fraction
        text = OnDeviceText.progress(of: run)
    }

    init(run: SubtitleRuns.Run) {
        fraction = run.state.fraction
        text = SubtitleText.progress(of: run)
    }

    var body: some View {
        VStack(spacing: 6) {
            if let fraction {
                ProgressView(value: fraction).progressViewStyle(.linear).frame(width: 120)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.scrim, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The run on a result's page: how far it is, and Cancel, which deletes what it wrote so far.
struct OnDeviceRunRow: View {
    let materialID: UUID

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        if let run = environment.onDevice.run(for: materialID) {
            HStack(spacing: Theme.Spacing.small) {
                if let fraction = run.state.fraction {
                    ProgressView(value: fraction).progressViewStyle(.linear)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(OnDeviceText.progress(of: run))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .layoutPriority(1)
                Button("Cancel") { environment.onDevice.cancel(run.id) }
                    .buttonStyle(.link)
            }
        }
    }
}
