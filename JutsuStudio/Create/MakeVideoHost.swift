import JutsuCore
import Presentation
import SwiftUI

/// Takes Make Video's images (`NavigationModel.pendingMakeVideo`) into the video form: placed at once when only one
/// role fits the selected model, else after asking which. Behind Create's video side, so its dialog stays off the
/// screen's modifier chain.
struct MakeVideoHost: View {
    /// False when the connection can't send start and end frames, so they aren't offered.
    let takesFrames: Bool

    @Environment(NavigationModel.self) private var navigation
    @State private var question: MakeVideoRequest?
    @State private var choices: [MakeVideoChoice] = []
    @State private var message: UserMessage?

    var body: some View {
        Color.clear
            .task(id: navigation.pendingMakeVideo) { take() }
            .confirmationDialog(
                title, isPresented: Binding(isPresenting: $question), titleVisibility: .visible, presenting: question
            ) { request in
                ForEach(choices) { choice in
                    Button(choice.title) { place(request, as: choice) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(detail)
            }
            .alert(message?.title ?? "", isPresented: Binding(isPresenting: $message), presenting: message) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message.message)
            }
    }

    private var title: String {
        (question?.images.count ?? 1) > 1
            ? String(localized: "How should \(navigation.createDraft.selectedModel.title) use these images?")
            : String(localized: "How should \(navigation.createDraft.selectedModel.title) use this image?")
    }

    /// Frames replace the source video; the toast offers it back.
    private var detail: String {
        choices.contains(where: \.usesFrames)
            ? String(localized: "A start or end frame makes the clip from the image alone, without a source video.")
            : String(localized: "References show the model what to draw from.")
    }

    private func take() {
        guard let request = navigation.pendingMakeVideo else { return }
        navigation.pendingMakeVideo = nil
        let offered = navigation.createDraft.makeVideoChoices(
            imageCount: request.images.count, takesFrames: takesFrames)
        switch offered.count {
        case 0:
            message = navigation.createDraft.makeVideoUnavailable
        case 1:
            place(request, as: offered[0])
        default:
            choices = offered
            question = request
        }
    }

    private func place(_ request: MakeVideoRequest, as choice: MakeVideoChoice) {
        message = navigation.replaceDraft { $0.makeVideo(from: request.images, as: choice) }
    }
}

/// What a change of model did to the images' roles, under the mode and model pickers until dismissed.
struct RoleChangeNote: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            Image(systemName: "info.circle")
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(.caption)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Dismiss", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.faint)
                .pointerCursor()
        }
        .padding(Theme.Spacing.medium)
        .well()
    }
}
