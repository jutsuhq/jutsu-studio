import JutsuCore
import MediaKit
import Presentation
import SwiftUI

/// What an Enhance run on this Mac is made from: an exact version of a library item, and its file.
struct OnDeviceTarget: Identifiable {
    enum Kind {
        case smoothMotion
        case upscaleVideo
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
    /// The file's frame rate, size and length, read once; `nil` until then.
    @State private var probed: MediaInfo?
    @State private var isUnreadable = false
    @State private var agreesToDownload = false

    private var action: OnDeviceAction {
        switch target.kind {
        case .smoothMotion: .smoothMotion(motion)
        case .upscaleVideo: .upscaleVideo
        }
    }

    private var needsConsent: Bool {
        environment.onDevice.needsConsent(action.engine)
    }

    private var offeredMotions: [SmoothMotion] {
        SmoothMotion.offered(sourceFrameRate: probed?.frameRate ?? 0)
    }

    /// The file is too large for the run, as read from the file itself.
    private var isTooLarge: Bool {
        guard let probed, target.kind == .upscaleVideo else { return false }
        return !OnDeviceUpscale.offersVideo(probed.pixelSize)
    }

    private var expectedTime: TimeInterval? {
        probed.map {
            switch target.kind {
            case .smoothMotion:
                OnDeviceEstimate.smoothMotion(duration: $0.duration, frameRate: $0.frameRate, pixelSize: $0.pixelSize)
            case .upscaleVideo:
                OnDeviceEstimate.upscaleVideo(duration: $0.duration, frameRate: $0.frameRate, pixelSize: $0.pixelSize)
            }
        }
    }

    private var canStart: Bool {
        probed != nil && !isTooLarge && (!needsConsent || agreesToDownload)
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
        case .upscaleVideo:
            SectionLabel(title: "Size")
            if let probed {
                Text(OnDeviceText.upscaleSizes(probed.pixelSize))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
            }
            Text(isTooLarge ? OnDeviceText.tooLargeVideo : OnDeviceText.upscaleSound)
                .font(.system(size: 12))
                .foregroundStyle(isTooLarge ? Theme.warning : Theme.muted)
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
        probed = try? await MediaProbe.probe(target.file)
        isUnreadable = probed == nil
        if !offeredMotions.contains(motion), let first = offeredMotions.first { motion = first }
    }
}

/// How far an Enhance run on this Mac is, over a library card.
struct OnDeviceRunBadge: View {
    let run: OnDeviceRuns.Run

    var body: some View {
        VStack(spacing: 6) {
            if let fraction = run.state.fraction {
                ProgressView(value: fraction).progressViewStyle(.linear).frame(width: 120)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(OnDeviceText.progress(of: run))
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
