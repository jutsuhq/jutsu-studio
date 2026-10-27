import JutsuCore
import Presentation
import SwiftUI

/// Settings › Subtitles: Parakeet Ultra, the speech model the app downloads itself, with its size, memory, languages
/// and license, and Download or Remove.
struct SubtitleSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    private var models: SpeechModels { environment.speechModels }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            SettingsSection(title: "Subtitles") {
                SettingsRow(label: "Model", detail: SubtitleText.autoNote, isFirst: true) {
                    SegmentedControl(
                        selection: Binding(
                            get: { environment.subtitles.defaultEngine },
                            set: { environment.subtitles.defaultEngine = $0 }),
                        options: SubtitleEngine.allCases.map { ($0, $0.title) }
                    )
                    .fixedSize()
                }
            }
            SettingsSection(title: SubtitleText.modelsFolder, footer: SubtitleText.parakeetCredit) {
                SettingsRow(label: SubtitleText.parakeetName, detail: SubtitleText.parakeetSummary, isFirst: true) {
                    control
                }
                SettingsRow(label: "Details", value: SubtitleText.parakeetFacts)
                SettingsRow(label: "Languages", value: SubtitleText.parakeetLanguages)
                SettingsRow(label: "Source") {
                    HStack(spacing: Theme.Spacing.small) {
                        if let url = ParakeetUltra.modelURL { Link("Hugging Face", destination: url) }
                        if let url = ParakeetUltra.licenseURL { Link(ParakeetUltra.license, destination: url) }
                    }
                }
            }
        }
        .alert(
            models.failure?.title ?? "",
            isPresented: Binding(get: { models.failure != nil }, set: { if !$0 { models.failure = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(models.failure?.message ?? "")
        }
    }

    @ViewBuilder private var control: some View {
        switch models.state {
        case .notDownloaded:
            Button("Download") { models.download() }
                .buttonStyle(.secondaryAction)
                .hoverHint("Downloads the model from Hugging Face into Jutsu Studio's own folder.")
        case .downloading(let fraction):
            HStack(spacing: Theme.Spacing.small) {
                ProgressView(value: fraction).frame(width: 120)
                Text(CostText.percent(fraction: fraction)).monospacedDigit()
                Button("Cancel") { models.cancel() }
                    .buttonStyle(.secondaryAction)
            }
        case .ready:
            HStack(spacing: Theme.Spacing.small) {
                Text(AppSettings.formatBytes(models.size))
                    .foregroundStyle(.secondary)
                Button("Remove") { models.remove() }
                    .buttonStyle(.secondaryAction)
            }
        }
    }
}
