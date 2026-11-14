import JutsuCore
import Presentation
import SwiftUI
import UniformTypeIdentifiers

/// The recording the characters say, on a model that takes one (`CreateForm.offersSpeech`): one audio file, added by
/// drop or the file picker, shown by name and length.
struct SpeechSection: View {
    @Binding var form: CreateForm
    let onPick: () -> Void
    /// Reads a dropped file's length, then sets it (`CreateView.importSpeech`).
    let onImport: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionLabel(title: "Speech", detail: form.speech.map { CostText.seconds($0.duration) })
            if let speech = form.speech {
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: "waveform")
                        .foregroundStyle(Theme.accent)
                    Text(speech.name)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    TileButton(
                        systemImage: "arrow.triangle.2.circlepath", help: String(localized: "Replace"), action: onPick)
                    TileButton(systemImage: "xmark", help: String(localized: "Remove")) { form.setSpeech(nil) }
                }
                .padding(Theme.Spacing.small)
                .well(radius: Theme.Radius.small)
            } else {
                DropButton(
                    title: String(localized: "Add speech"),
                    detail: String(localized: "A voice recording the characters say"), systemImage: "waveform",
                    action: onPick)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: Self.isAudio) else { return false }
            onImport(url)
            return true
        }
    }

    static func isAudio(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true
    }
}
