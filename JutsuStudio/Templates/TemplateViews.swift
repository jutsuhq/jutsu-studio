import JutsuCore
import Persistence
import Presentation
import SwiftData
import SwiftUI

/// The Templates icon button in the Create header: start from a template, save the side in front as one,
/// or manage them.
struct TemplatesMenu: View {
    /// The side Create is on: its templates list first, and the form is saved as one of them.
    let kind: TemplateKind
    let form: CreateForm
    /// What the connection runs; a template on another model falls back to Genjutsu.
    let offeredModels: Set<VideoModel>

    @Environment(AppEnvironment.self) private var environment
    @Query(TemplateRecord.byName) private var templates: [TemplateRecord]

    @State private var isNaming = false
    @State private var name = ""
    @State private var isManaging = false
    @State private var alert: UserMessage?

    var body: some View {
        Menu {
            Section("New from template") {
                if orderedTemplates.isEmpty {
                    Text("No templates yet")
                }
                ForEach(orderedTemplates) { record in
                    Button(record.name) { apply(record) }
                }
            }
            Divider()
            Button("Save as Template…", systemImage: "square.and.arrow.down") {
                name = suggestedName
                isNaming = true
            }
            Button("Manage Templates…", systemImage: "list.bullet") { isManaging = true }
                .disabled(templates.isEmpty)
        } label: {
            Label("Templates", systemImage: "square.stack")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .buttonStyle(.secondaryAction)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverHint("Templates")
        .templateNameAlert(
            String(localized: "Save as Template"), isPresented: $isNaming, name: $name,
            confirmTitle: String(localized: "Save")
        ) {
            save()
        }
        .sheet(isPresented: $isManaging) {
            TemplatesSheet { record in
                apply(record)
                isManaging = false
            }
        }
        .alert(alert?.title ?? "", isPresented: Binding(isPresenting: $alert), presenting: alert) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message.message)
        }
    }

    /// The templates of the current side first, then by name.
    private var orderedTemplates: [TemplateRecord] { sortedTemplates(templates, kind: kind) }

    private var suggestedName: String {
        if kind == .image {
            TemplateNaming.suggestedName(kind: kind, prompt: environment.referenceGenerator.prompt)
        } else {
            TemplateNaming.suggestedName(mode: form.mode, prompt: form.prompt)
        }
    }

    private func apply(_ record: TemplateRecord) {
        do {
            environment.useTemplate(try record.template(), offeredModels: offeredModels)
        } catch {
            alert = UserMessage(
                title: String(localized: "Can't open the template"), message: error.localizedDescription)
        }
    }

    private func save() {
        do {
            if kind == .image {
                try environment.saveTemplate(environment.referenceGenerator.makeImageTemplate(name: name))
            } else {
                try environment.saveTemplate(form.makeTemplate(name: name))
            }
        } catch {
            alert = .templateNotSaved(error)
        }
    }
}

/// The templates of `kind` first, each group in the order given. One that can't be read counts as video, as old
/// ones decode.
func sortedTemplates(_ templates: [TemplateRecord], kind: TemplateKind) -> [TemplateRecord] {
    let isKind = templates.map { ((try? $0.template().kind) ?? .video) == kind }
    let indices = templates.indices
    return indices.filter { isKind[$0] }.map { templates[$0] } + indices.filter { !isKind[$0] }.map { templates[$0] }
}

/// File › New from Template: starts Create from a template from any page, the current side's templates first.
struct NewFromTemplateMenu: View {
    let environment: AppEnvironment
    /// Brings the main window forward, where Create shows the template.
    let onUse: () -> Void

    @Query(TemplateRecord.byName) private var templates: [TemplateRecord]

    var body: some View {
        Menu("New from Template") {
            if templates.isEmpty {
                Text("No templates yet")
            }
            ForEach(sortedTemplates(templates, kind: environment.navigation.createKind)) { record in
                Button(record.name) { use(record) }
            }
        }
    }

    private func use(_ record: TemplateRecord) {
        do {
            environment.useTemplate(try record.template(), offeredModels: environment.lastOfferedModels)
        } catch {
            environment.navigation.templateNotice = UserMessage(
                title: String(localized: "Can't open the template"), message: error.localizedDescription)
            environment.navigation.selection = .create
        }
        onUse()
    }
}

/// Every template with its inputs; use, rename or delete one.
private struct TemplatesSheet: View {
    let onUse: (TemplateRecord) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Query(TemplateRecord.byName) private var templates: [TemplateRecord]

    @State private var isRenaming = false
    /// Not cleared on dismiss: the alert's button may run after the alert is gone.
    @State private var renameTarget: TemplateRecord?
    @State private var name = ""
    @State private var deleting: TemplateRecord?
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            Text("Templates")
                .font(.title2.bold())
                .foregroundStyle(Theme.text)
            if templates.isEmpty {
                Text("No templates yet. Save the Create form as one from the Templates menu.")
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: Theme.Spacing.small) {
                        ForEach(templates) { record in
                            row(record)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.secondaryAction)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: 460, height: 420)
        .background(Theme.background)
        .templateNameAlert(
            String(localized: "Rename Template"), isPresented: $isRenaming, name: $name,
            confirmTitle: String(localized: "Rename")
        ) {
            rename()
        }
        .confirmationDialog(
            "Delete “\(deleting?.name ?? "")”?", isPresented: Binding(isPresenting: $deleting),
            titleVisibility: .visible, presenting: deleting
        ) { record in
            Button("Delete Template", role: .destructive) { delete(record) }
        } message: { _ in
            Text("Its copied reference images are deleted too. Jobs already made from it keep their results.")
        }
        .alert("Can't change the template", isPresented: Binding(isPresenting: $errorText)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private func row(_ record: TemplateRecord) -> some View {
        HStack(spacing: Theme.Spacing.medium) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text((try? record.template().summary) ?? "")
                    .font(.caption)
                    .foregroundStyle(Theme.faint)
            }
            Spacer(minLength: Theme.Spacing.small)
            Button("Use") { onUse(record) }
                .buttonStyle(.secondaryAction)
            Button("Rename", systemImage: "pencil") {
                name = record.name
                renameTarget = record
                isRenaming = true
            }
            .buttonStyle(.iconAction)
            .hoverHint("Rename")
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = record }
                .buttonStyle(.iconAction)
                .hoverHint("Delete")
        }
        .padding(Theme.Spacing.medium)
        .well()
    }

    private func rename() {
        guard let record = renameTarget else { return }
        do {
            try environment.renameTemplate(record, to: name)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func delete(_ record: TemplateRecord) {
        do {
            try environment.deleteTemplate(record)
        } catch {
            errorText = error.localizedDescription
        }
    }
}

extension View {
    /// An alert with a name field, for saving and renaming templates. The name is made unique on save.
    func templateNameAlert(
        _ title: String, isPresented: Binding<Bool>, name: Binding<String>, confirmTitle: String,
        onConfirm: @escaping () -> Void
    ) -> some View {
        alert(title, isPresented: isPresented) {
            TextField("Name", text: name)
            Button(confirmTitle, action: onConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Reference images are copied, so the template keeps working when the originals move.")
        }
    }
}
