import AppKit
import JutsuCore
import Presentation
import SwiftUI

/// What a result is and what went into it: title, settings, prompt and input media.
struct ResultSummary: View {
    let item: LibraryItemModel
    /// Width over height of the source.
    let aspect: CGFloat
    @State private var isSavingInputs = false
    @State private var message: UserMessage?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            header
            if !item.spec.prompt.isEmpty { prompt }
            inputs
        }
        .alert(message?.title ?? "", isPresented: Binding(isPresenting: $message), presenting: message) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message.message)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(item.headline(now: context.date))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.faint)
            }
            Text(item.title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: 6) {
                ForEach(item.facts, id: \.self) { fact in
                    Text(fact)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Theme.glass, in: Capsule())
                }
            }
            .padding(.top, 2)
        }
    }

    private var prompt: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack {
                SectionLabel(title: "Prompt")
                CopyButton(text: item.spec.prompt)
            }
            Text(item.spec.prompt)
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1)
        }
    }

    /// The source frame and the reference images that went in; each can be saved back to the Mac.
    private var inputs: some View {
        let source = item.spec.source
        let references = item.spec.references
        let files = InputFile.all(in: item)
        return VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                SectionLabel(title: "Inputs", detail: item.rangeText)
                saveInputsButton(files)
            }
            HStack(spacing: Theme.Spacing.small) {
                if let source {
                    FrameTile(url: source.fileURL, bookmark: source.bookmark)
                        .frame(width: 64 * min(max(aspect, 0.56), 1.78), height: 64)
                        .contextMenu { inputMenu(files.first { $0.role == .source }) }
                }
                ForEach(Array(references.prefix(4).enumerated()), id: \.offset) { index, reference in
                    ReferenceThumb(reference: reference)
                        .frame(width: 52, height: 52)
                        .contextMenu { inputMenu(files.first { $0.role == .reference(index + 1) }) }
                }
                if references.count > 4 {
                    Text("+\(references.count - 4)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                }
            }
            Text(Self.sourceLine(source))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

extension ResultSummary {
    /// The source file's name; for a clip made without one, that it was made from the prompt.
    static func sourceLine(_ source: SourceClip?) -> String {
        guard let source else { return String(localized: "No source video · made from the prompt") }
        return source.fileURL.isFileURL ? source.fileURL.lastPathComponent : String(localized: "Source on Higgsfield")
    }

    @ViewBuilder
    fileprivate func saveInputsButton(_ files: [InputFile]) -> some View {
        if isSavingInputs {
            ProgressView().controlSize(.mini).accessibilityLabel("Saving inputs")
        } else if !files.isEmpty {
            Button("Save Inputs…", systemImage: "square.and.arrow.down") { save(files) }
                .buttonStyle(.iconAction)
                .controlSize(.small)
                .hoverHint("Save inputs")
        }
    }

    @ViewBuilder
    fileprivate func inputMenu(_ file: InputFile?) -> some View {
        if let file {
            Button("Save \(file.title)…", systemImage: "square.and.arrow.down") { save([file]) }
            if let local = file.local, FileManager.default.fileExists(atPath: local.fileURL.path) {
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([local.fileURL])
                }
            }
        }
    }

    fileprivate func save(_ files: [InputFile]) {
        guard !isSavingInputs else { return }
        isSavingInputs = true
        Task {
            message = await InputExport.run(files, base: item.sourceName)
            isSavingInputs = false
        }
    }
}

/// "‹ 2 of 5 ›"; the plain arrow keys work too.
struct ResultPager: View {
    let position: Int
    let count: Int
    let step: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button("Previous", systemImage: "chevron.left") { step(-1) }
                .disabled(position <= 1)
                .keyboardShortcut(.leftArrow, modifiers: [])
                .hoverHint("Previous result (←)")
            Text("\(position) of \(count)")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.faint)
                .frame(minWidth: 52)
            Button("Next", systemImage: "chevron.right") { step(1) }
                .disabled(position >= count)
                .keyboardShortcut(.rightArrow, modifiers: [])
                .hoverHint("Next result (→)")
        }
        .buttonStyle(.iconAction)
    }
}

/// Copies a text and confirms with a checkmark for a moment.
struct CopyButton: View {
    let text: String
    @State private var didCopy = false

    var body: some View {
        Button {
            NSPasteboard.general.copyText(text)
            didCopy = true
        } label: {
            Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(didCopy ? Theme.accent : Theme.muted)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .task(id: didCopy) {
            guard didCopy else { return }
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }
}

extension NSPasteboard {
    func copyText(_ text: String) {
        clearContents()
        setString(text, forType: .string)
    }

    /// Puts files on the pasteboard as Finder's Copy does, to paste into a folder or another app.
    func copyFiles(_ urls: [URL]) {
        clearContents()
        writeObjects(urls.map { $0 as NSURL })
    }
}
