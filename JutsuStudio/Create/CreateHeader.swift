import JutsuCore
import Presentation
import SwiftUI

/// Create's title with the Video | Image switch and the Templates icon beside it. It also shows what applying a
/// template reported, and keeps the saved Image draft in step with Generate…'s form.
struct CreateHeader: View {
    /// The video form, for the subtitle and to save as a template.
    let form: CreateForm
    /// What the connection runs; a video template on another model falls back.
    let offeredModels: Set<VideoModel>

    @Environment(AppEnvironment.self) private var environment
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation
        PageHeader(title: "Create", subtitle: navigation.createKind.tagline ?? form.mode.tagline) {
            HStack(spacing: Theme.Spacing.small) {
                SegmentedControl(selection: $navigation.createKind) { $0.title }
                    .fixedSize()
                TemplatesMenu(kind: navigation.createKind, form: form, offeredModels: offeredModels)
            }
        }
        // Applying a template, also from the menu bar, opens Create to show what it reports.
        .alert(
            navigation.templateNotice?.title ?? "", isPresented: Binding(isPresenting: $navigation.templateNotice),
            presenting: navigation.templateNotice
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { report in
            Text(report.message)
        }
        // The Image side's form is Generate…'s, also edited from References › Generate…; both are on Create, so
        // following it here keeps the saved draft current.
        .onChange(of: environment.referenceGenerator.snapshot()) { _, snapshot in
            navigation.imageDraft = snapshot
        }
    }
}
