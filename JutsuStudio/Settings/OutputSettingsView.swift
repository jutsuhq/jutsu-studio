import JutsuCore
import Presentation
import SwiftUI
import UniformTypeIdentifiers

/// Output folder, resolutions, parallel jobs and file names.
struct OutputSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @AppStorage(AppSettings.defaultResolutionKey) private var resolution = AppSettings.defaultResolution
    @AppStorage(AppSettings.draftResolutionKey) private var draftResolution = AppSettings.defaultDraftResolution
    @Environment(ConnectionStore.self) private var connection
    /// `nil` until set here; the connection's default applies then.
    @AppStorage(AppSettings.maxConcurrencyKey) private var storedConcurrency: Int?
    @AppStorage(AppSettings.outputNamePatternKey) private var namePattern = OutputNamePattern.defaultPattern
    @FocusState private var isPatternFocused: Bool
    @State private var isPickingFolder = false
    @State private var errorText = ""
    @State private var isShowingError = false

    /// The defaults every model without its own list renders at; MiniMax's 768p and 2K are picked in Create.
    private static let resolutions: [(value: Resolution, title: String)] = Resolution.standard.map {
        ($0, $0.rawValue)
    }

    private var maxConcurrency: Binding<Int> {
        Binding(
            get: { AppSettings.maxConcurrency(stored: storedConcurrency, for: connection.state.kind) },
            set: { storedConcurrency = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            SettingsSection(
                title: "Results",
                footer: String(localized: "Results download here automatically when a job finishes.")
            ) {
                SettingsRow(
                    label: "Folder", detail: AppSettings.displayPath(folderPath), isFirst: true
                ) {
                    HStack(spacing: Theme.Spacing.small) {
                        if environment.outputFolder.isCustom {
                            Button("Use Default") { setFolder(nil) }
                        }
                        Button("Change…") { isPickingFolder = true }
                    }
                    .buttonStyle(.secondaryAction)
                }
                SettingsRow(label: "Default resolution") {
                    SegmentedControl(selection: $resolution, options: Self.resolutions)
                        .fixedSize()
                }
                SettingsRow(label: "Draft resolution") {
                    SegmentedControl(selection: $draftResolution, options: Self.resolutions)
                        .fixedSize()
                }
                SettingsRow(
                    label: "Parallel jobs",
                    detail: String(
                        localized: """
                            Generating at once. By default \(AppSettings.defaultAccountMaxConcurrency) on an account, \
                            \(AppSettings.defaultMaxConcurrency) with an API key
                            """)
                ) {
                    ValueStepper(
                        label: String(localized: "Parallel jobs"), value: maxConcurrency,
                        range: AppSettings.maxConcurrencyRange)
                }
            }
            SettingsSection(title: "File names", footer: nameFooter) {
                SettingsRow(label: "Pattern", isFirst: true) {
                    HStack(spacing: Theme.Spacing.small) {
                        Menu("Templates") {
                            ForEach(AppSettings.outputNameTemplates) { template in
                                Button(template.title) { namePattern = template.pattern }
                            }
                        }
                        .menuStyle(.button)
                        .buttonStyle(.secondaryAction)
                        .fixedSize()
                        TextField("Pattern", text: $namePattern)
                            .font(.system(size: 13, design: .monospaced))
                            .focused($isPatternFocused)
                            .themedField(isFocused: isPatternFocused)
                            .frame(width: 240)
                            .hoverHint(tokenHelp)
                    }
                }
                SettingsRow(label: "Example") {
                    Text(AppSettings.outputNameExample(namePattern))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): setFolder(url)
            case .failure(let error): show(error)
            }
        }
        .onChange(of: maxConcurrency.wrappedValue) { _, limit in
            environment.setMaxConcurrency(limit)
        }
        .onChange(of: namePattern) { _, pattern in
            environment.setOutputNamePattern(pattern)
        }
        .alert("Can't change this setting", isPresented: $isShowingError) {
            Button("OK") {}
        } message: {
            Text(errorText)
        }
    }

    private var folderPath: String {
        environment.outputFolder.url.path(percentEncoded: false)
    }

    private var nameFooter: String {
        let tokens = OutputNamePattern.Token.allCases.map(\.placeholder).joined(separator: " ")
        let usage = String(
            localized: "Tokens: \(tokens). Applies to new results only; a name already in the folder gets -2, -3…")
        guard !OutputNamePattern.isValid(namePattern) else { return usage }
        return String(localized: "Empty pattern or unknown token: the default is used.") + " " + usage
    }

    private var tokenHelp: String {
        OutputNamePattern.Token.allCases.map { "\($0.placeholder) — \($0.meaning)" }.joined(separator: "\n")
    }

    private func setFolder(_ folder: URL?) {
        Task {
            do {
                try await environment.setOutputFolder(folder)
            } catch {
                show(error)
            }
        }
    }

    private func show(_ error: any Error) {
        errorText = error.localizedDescription
        isShowingError = true
    }
}
