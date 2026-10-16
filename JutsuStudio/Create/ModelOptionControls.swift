import JutsuCore
import Presentation
import SwiftUI

/// Kling's options under the model picker: the background and which way the character faces. Each is disabled, with
/// the reason as its help, where the connection can't send it.
struct KlingOptions: View {
    @Binding var form: CreateForm
    let context: CreateContext

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if form.showsVideoBackground {
                backgroundToggle
            }
            if form.showsCharacterOrientation {
                orientationPicker
            }
        }
    }

    /// Off as well as disabled where the connection can't keep the background.
    private var backgroundToggle: some View {
        let reason = context.unavailableHint(for: .klingVideoBackground)
        return HStack(spacing: Theme.Spacing.small) {
            Text("Keep the video's background")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
            Toggle(
                "Keep the video's background",
                isOn: reason == nil ? $form.keepsVideoBackground : .constant(false)
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(Theme.accent)
            .labelsHidden()
        }
        .disabled(reason != nil)
        .hoverHint(reason.map { Text($0) } ?? Text("Use the video's scene"))
    }

    private var orientationPicker: some View {
        let reason = context.unavailableHint(for: .klingOrientation)
        return VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("Character faces")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.muted)
            SegmentedControl(selection: $form.characterOrientation) { $0.title }
        }
        .disabled(reason != nil)
        .hoverHint(reason.map { Text($0) } ?? Text("Follow the image or video"))
    }
}

/// Seedance's bitrate, under its resolution. Disabled, with the reason as its help, where the connection can't set it.
struct BitratePicker: View {
    @Binding var form: CreateForm
    let context: CreateContext

    var body: some View {
        let reason = context.unavailableHint(for: .seedanceBitrate)
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionLabel(title: "Quality")
            SegmentedControl(selection: bitrate) { $0.title }
        }
        .disabled(reason != nil)
        .hoverHint(reason.map { Text($0) } ?? Text("Video bitrate"))
    }

    /// Until one is picked, the connection's own default.
    private var bitrate: Binding<SeedanceBitrate> {
        Binding(
            get: { form.bitrate(on: context.connection.kind) },
            set: { form.setBitrate($0) })
    }
}

/// Cinema Studio's creative controls under the model picker: one closed row that opens to a menu per control, each
/// on Auto (the director picks it) until set. Disabled, with the reason as its help, where the connection can't send
/// them.
struct CinemaOptions: View {
    @Binding var form: CreateForm
    let context: CreateContext
    @State private var isOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let reason = context.unavailableHint(for: .cinemaControls)
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { isOpen.toggle() }
            } label: {
                HStack(spacing: Theme.Spacing.small) {
                    Text("Direction")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.muted)
                    Spacer(minLength: Theme.Spacing.small)
                    Text(summary)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(form.cinemaControlsSummary == nil ? Theme.faint : Theme.accent)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.faint)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityValue(summary)
            .accessibilityHint(isOpen ? Text("Hides the controls") : Text("Shows the controls"))
            if isOpen {
                VStack(spacing: 0) {
                    ForEach(Array(CinemaControl.allCases.enumerated()), id: \.element) { index, control in
                        if index > 0 { Divider() }
                        row(control)
                    }
                }
                .padding(.horizontal, Theme.Spacing.medium)
                .well()
                .disabled(reason != nil)
            }
        }
        .hoverHint(reason.map { Text($0) } ?? Text("Camera, lens, genre and more"))
    }

    /// "2 set", or Auto with none set.
    private var summary: String { form.cinemaControlsSummary ?? String(localized: "Auto") }

    private func row(_ control: CinemaControl) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(control.title)
                .font(.callout)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer(minLength: Theme.Spacing.small)
            FilterMenu(
                title: control.title,
                selection: Binding(get: { form[cinema: control] }, set: { form[cinema: control] = $0 }),
                options: [(nil, String(localized: "Auto"))] + control.options.map { ($0, control.title(of: $0)) })
        }
        .frame(minHeight: 40)
    }
}
