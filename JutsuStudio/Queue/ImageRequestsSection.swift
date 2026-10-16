import Presentation
import SwiftUI

/// Generate… requests, from the Image side of Create or from References: they run beside the job queue
/// (`ReferenceGenerator`), so they are listed on their own, with Cancel while they run. Their images are on the
/// Image side of Create and in Library › Images.
struct ImageRequestsSection: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        let generator = environment.referenceGenerator
        if !generator.runs.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
                SectionLabel(title: "Images", detail: "\(generator.runs.count)")
                Button("Show in Create") {
                    navigation.createKind = .image
                    navigation.selection = .create
                }
                .buttonStyle(.link)
                .font(.system(size: 11, weight: .semibold))
                .hoverHint(String(localized: "Show images in Create"))
            }
            .padding(.top, 18)
            ForEach(generator.runs) { run in
                ImageRunRow(run: run) { generator.cancel(run.id) }
            }
        }
    }
}
