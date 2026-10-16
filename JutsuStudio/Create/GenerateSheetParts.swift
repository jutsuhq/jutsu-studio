import AppKit
import JutsuCore
import Presentation
import SwiftUI

/// The frame Generate reference images and Create Character share: a header with the title and the close cross, the
/// form on the left, what the requests made on the right, and the actions under both. While the sheet is busy, the
/// form and the cross wait.
struct GenerateSheetLayout<Form: View, Results: View, Actions: View>: View {
    let title: String
    let subtitle: String
    var formWidth: CGFloat = 380
    let isBusy: Bool
    /// The cross's tooltip: why it waits, or "Close".
    let closeHint: String
    /// Escape closes the sheet; off while a view over it takes Escape.
    var closesOnEscape = true
    let onClose: () -> Void
    @ViewBuilder let form: () -> Form
    @ViewBuilder let results: () -> Results
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            header
            HStack(alignment: .top, spacing: 24) {
                ScrollView {
                    form()
                        .disabled(isBusy)
                        .opacity(isBusy ? 0.55 : 1)
                }
                .frame(width: formWidth)
                Divider()
                results()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: Theme.Spacing.small) {
                actions()
            }
        }
        .padding(24)
        .frame(minWidth: 940, idealWidth: 1000, minHeight: 560, idealHeight: 720)
        .background(Theme.background)
    }

    /// The title, and the cross that closes the sheet: away from Generate, so it isn't mistaken for an action.
    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.medium) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Spacing.medium)
            Button("Close", systemImage: "xmark", action: onClose)
                .buttonStyle(.iconAction)
                .keyboardShortcut(closesOnEscape ? .cancelAction : nil)
                .disabled(isBusy)
                .hoverHint(closeHint)
        }
    }
}

/// A setting on one line of a form's well: its name on the left, the control on the right.
struct OptionRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: () -> Control

    /// A literal title, looked up in the string catalog.
    init(title: LocalizedStringResource, detail: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.init(title: String(localized: title), detail: detail, control: control)
    }

    /// A title that is already localized. Disfavored, as in SwiftUI's `Text`, so a literal picks the catalog.
    @_disfavoredOverload
    init(title: String, detail: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(Theme.text)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.faint)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: Theme.Spacing.small)
            control()
        }
        .padding(.vertical, 6)
        .frame(minHeight: 44)
    }
}

/// A picked image in an option row, with the cross that removes it.
struct RemovableThumb: View {
    let image: LocalImage
    let onRemove: () -> Void

    var body: some View {
        ReferenceThumb(reference: image)
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .topTrailing) {
                TileButton(systemImage: "xmark", help: String(localized: "Remove"), action: onRemove)
                    .offset(x: 8, y: -8)
            }
    }
}

/// Generate with its price, as on Create's Generate: in a tag on the primary button, plain on a secondary one. No
/// price while it's being quoted or can't be.
struct GenerateButtonLabel: View {
    let isGenerating: Bool
    let price: String?
    var isPrimary = true

    var body: some View {
        HStack(spacing: 6) {
            if isGenerating {
                ProgressView()
                    .controlSize(.small)
                Text("Generating…")
            } else {
                Image(systemName: "sparkles")
                Text("Generate")
                if let price, isPrimary {
                    PriceTag(text: price)
                } else if let price {
                    Text(price)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
            }
        }
    }
}

/// One request on a line: a spinner and Cancel while it runs, else how it ended.
struct RequestRow: View {
    enum Status: Hashable {
        case working(String)
        case finished(String?)
        case failed(String)
        case canceled
    }

    let title: String
    let status: Status
    /// Shown while it runs, when the request can be canceled.
    var onCancel: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                detail
            }
            Spacer(minLength: Theme.Spacing.small)
            if case .working = status, let onCancel {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.secondaryAction)
                    .controlSize(.small)
                    .hoverHint("A request Higgsfield hasn't started yet isn't charged")
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, 10)
        .well()
    }

    @ViewBuilder private var icon: some View {
        switch status {
        case .working:
            ProgressView()
                .controlSize(.small)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.accent)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
        case .canceled:
            Image(systemName: "xmark.circle")
                .foregroundStyle(Theme.faint)
        }
    }

    @ViewBuilder private var detail: some View {
        switch status {
        case .working(let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(Theme.muted)
        case .finished(let text?):
            Text(text)
                .font(.caption)
                .foregroundStyle(Theme.faint)
        case .finished(nil):
            EmptyView()
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        case .canceled:
            Text("Canceled")
                .font(.caption)
                .foregroundStyle(Theme.faint)
        }
    }
}

/// Shown while Jutsu Studio can't write down the prices and jobs of its image requests: what it holds is known to
/// this launch only. Try Again writes everything again; Copy Job IDs keeps the jobs Higgsfield accepted, so they can
/// be found in the account's history after a quit.
struct UnsavedRecordsWarning: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        if let unsaved = environment.unsavedRecords {
            VStack(alignment: .leading, spacing: 6) {
                Label(unsaved.reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    unsaved.jobIDs.isEmpty
                        ? String(localized: "Prices and requests from now on are kept only until you quit.")
                        : String(
                            localized:
                                "Higgsfield accepted \(unsaved.jobIDs.count) jobs that would be lost on quit. Copy their IDs to find them in your Higgsfield history."
                        )
                )
                .font(.caption)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Spacing.small) {
                    Button("Try Again") { environment.retrySavingRecords() }
                    if !unsaved.jobIDs.isEmpty {
                        Button("Copy Job IDs") {
                            NSPasteboard.general.copyText(unsaved.jobIDs.joined(separator: "\n"))
                        }
                    }
                }
                .buttonStyle(.secondaryAction)
                .controlSize(.small)
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .well()
        }
    }
}
