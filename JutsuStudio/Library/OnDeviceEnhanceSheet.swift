import JutsuCore
import MediaKit
import Presentation
import SwiftUI

/// What an Enhance run on this Mac is made from: an exact version of a library item, and its file.
struct OnDeviceTarget: Identifiable {
    enum Kind {
        case smoothMotion
    }

    let id = UUID()
    let kind: Kind
    let source: MaterialReference
    let file: URL
    /// The item's title, under the sheet's.
    let title: String
}

/// The options of an Enhance run on this Mac, how long it takes and that it is free. Starting it adds it to
/// `OnDeviceRuns`, which runs one at a time; the item's card shows how far it is.
struct OnDeviceEnhanceSheet: View {
    let target: OnDeviceTarget

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var motion = SmoothMotion.fps60
    /// The file's frame rate, size and length, read once; `nil` until then.
    @State private var probed: MediaInfo?
    @State private var isUnreadable = false

    private var action: OnDeviceAction { .smoothMotion(motion) }

    private var offeredMotions: [SmoothMotion] {
        SmoothMotion.offered(sourceFrameRate: probed?.frameRate ?? 0)
    }

    private var expectedTime: TimeInterval? {
        probed.map {
            OnDeviceEstimate.smoothMotion(duration: $0.duration, frameRate: $0.frameRate, pixelSize: $0.pixelSize)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Smooth Motion")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text(target.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            options
            notes
            actions
        }
        .padding(24)
        .frame(width: 440)
        .background(Theme.background)
        .task { await probe() }
    }

    @ViewBuilder private var options: some View {
        SectionLabel(title: "Motion")
        SegmentedControl(selection: $motion, options: offeredMotions.map { ($0, $0.title) })
        Text(motion.keepsAudio ? OnDeviceText.smoothMotionNote : OnDeviceText.slowMotionSound)
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)
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
                environment.startOnDevice(action, source: target.source, file: target.file)
                dismiss()
            } label: {
                HStack(spacing: Theme.Spacing.small) {
                    Label(action.title, systemImage: "wand.and.rays")
                    PriceTag(text: String(localized: "Free"))
                }
            }
            .buttonStyle(.primaryAction)
            .keyboardShortcut(.defaultAction)
            .disabled(probed == nil)
        }
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
            if case .working(let fraction) = run.state {
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
                if case .working(let fraction) = run.state {
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
