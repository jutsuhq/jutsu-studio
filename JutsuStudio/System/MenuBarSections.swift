import AppKit
import Presentation
import SwiftUI

// The menu bar panel's sections below the header (`MenuBarContent`): rows on the panel's own material, in cards
// whose corners follow the panel's, with vibrant label colors. Lime is for controls and state, the signature
// gradient for render progress only.

/// Today's agent budget: what is spent and reserved on a thin bar, what is left, and the person's own cap.
struct MenuBarTodaySection: View {
    let today: MenuBarPanel.Today

    var body: some View {
        PanelSection(title: "Today") {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(today.spent)
                        .font(.callout.weight(.medium))
                    Spacer(minLength: 8)
                    if let limit = today.limit {
                        Text(limit)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                BudgetBar(spent: today.spentFraction, reserved: today.reservedFraction)
                HStack {
                    if let reserved = today.reserved { Text(reserved) }
                    Spacer(minLength: 8)
                    Text(today.remaining)
                        .foregroundStyle(today.isUsedUp ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(.secondary))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let cap = today.cap {
                    Text(cap)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .lineLimit(1)
            .monospacedDigit()
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .accessibilityElement(children: .combine)
        }
    }
}

/// Spent, then reserved, on a track: lime for state, never the brand gradient.
private struct BudgetBar: View {
    let spent: Double
    let reserved: Double

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                Rectangle().fill(Theme.accent).frame(width: proxy.size.width * spent)
                Rectangle().fill(Theme.accent.opacity(0.4)).frame(width: proxy.size.width * reserved)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 4)
        .background(.quaternary)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

/// Held jobs and agents' requests for a model download; each opens where the person settles it.
struct MenuBarNeedsYouSection: View {
    let items: [MenuBarPanel.Attention]
    let overflow: String?
    let open: (MenuBarPanel.AttentionTarget) -> Void

    var body: some View {
        PanelSection(title: "Needs you", overflow: overflow) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { PanelDivider() }
                PanelRowButton(help: help(item.target)) {
                    open(item.target)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.warning)
                            .accessibilityHidden(true)
                        TitleAndDetail(title: item.title, detail: item.reason, detailLines: 2)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private func help(_ target: MenuBarPanel.AttentionTarget) -> String {
        switch target {
        case .job: String(localized: "Show in the Queue")
        case .sheet: String(localized: "Open the item's sheet")
        }
    }
}

/// Paid jobs and runs on this Mac, with progress and Cancel.
struct MenuBarRunningSection: View {
    let items: [MenuBarPanel.Running]
    let overflow: String?
    let open: (UUID) -> Void
    let cancel: (MenuBarPanel.Running) -> Void

    var body: some View {
        PanelSection(title: "Running", overflow: overflow) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { PanelDivider() }
                HStack(alignment: .center, spacing: 8) {
                    // A job opens its Queue row; a run on this Mac has no row to open, so it isn't a button.
                    if item.kind == .job {
                        PanelRowButton(help: String(localized: "Show in the Queue")) {
                            open(item.id)
                        } label: {
                            row(item)
                        }
                    } else {
                        row(item).panelRowPadding()
                    }
                    if let cancel = item.cancel {
                        Button {
                            self.cancel(item)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.secondary)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!cancel.isEnabled)
                        .help(cancel.help)
                        .accessibilityLabel(String(localized: "Cancel \(item.title)"))
                        .padding(.trailing, 8)
                    }
                }
            }
        }
    }
}

extension MenuBarRunningSection {
    fileprivate func row(_ item: MenuBarPanel.Running) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            TitleAndDetail(title: item.title, detail: item.detail)
            if let progress = item.progress {
                RenderProgress(value: progress)
            } else if let estimate = item.estimate {
                RenderProgress(value: estimate.fraction, estimate: estimate.label)
            }
        }
    }
}

/// The last results, each with a frame; a click opens it in Library, Show in Finder reveals its file.
struct MenuBarRecentSection: View {
    let items: [MenuBarPanel.Recent]
    let open: (UUID) -> Void

    var body: some View {
        PanelSection(title: "Recent") {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { PanelDivider() }
                HStack(spacing: 8) {
                    PanelRowButton(help: String(localized: "Show in Library")) {
                        open(item.id)
                    } label: {
                        HStack(spacing: 10) {
                            PanelThumbnail(url: item.file)
                            TitleAndDetail(title: item.title, detail: item.detail)
                        }
                    }
                    if let file = item.file, file.isFileURL {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([file])
                        } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show in Finder")
                        .accessibilityLabel(String(localized: "Show \(item.title) in Finder"))
                        .padding(.trailing, 10)
                    }
                }
                .contextMenu {
                    Button("Show in Library") { open(item.id) }
                    if let file = item.file, file.isFileURL {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    }
                }
            }
        }
    }
}

// MARK: Building blocks

/// A section's title over its card, with "and 2 more" under it.
private struct PanelSection<Content: View>: View {
    let title: LocalizedStringKey
    var overflow: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            PanelCard { content }
            if let overflow {
                Text(overflow)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }
        }
    }
}

/// A result's frame, small: decoded once through the Library's cache, a film symbol until then or without a file.
private struct PanelThumbnail: View {
    let url: URL?
    @State private var image: CGImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(.quaternary)
            .frame(width: 48, height: 27)
            .overlay {
                if let image {
                    FittedFrame(image: image, tileAspect: 48 / 27)
                } else {
                    Image(systemName: "film").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityHidden(true)
            .task(id: url) {
                image = if let url { await ThumbnailCache.shared.image(for: url) } else { nil }
            }
    }
}

private struct TitleAndDetail: View {
    let title: String
    let detail: String
    var detailLines = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(detailLines)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PanelDivider: View {
    var body: some View {
        Divider().padding(.leading, 10)
    }
}

/// A whole row that opens something, lit on hover as a menu item is.
private struct PanelRowButton<Label: View>: View {
    let help: String?
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label
                .panelRowPadding()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background { if isHovered { Rectangle().fill(.quaternary) } }
        .onHover { isHovered = $0 }
        .help(help ?? "")
    }
}

/// A card on the panel's material: a quiet fill, its corners concentric with the panel's on macOS 26, and an outline
/// with Increase Contrast.
struct PanelCard<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(PanelLook.cardShape)
            .background(PanelLook.cardShape.fill(.quinary))
            .overlay {
                if contrast == .increased { PanelLook.cardShape.stroke(.secondary, lineWidth: 1) }
            }
    }
}

/// Liquid Glass on macOS 26, standard materials and bordered controls before it.
@MainActor
enum PanelLook {
    static var usesGlass: Bool {
        #if DEBUG
            if DebugLaunchHooks.forcesMaterialFallback { return false }
        #endif
        if #available(macOS 26, *) { return true }
        return false
    }

    static var cardShape: AnyShape {
        if #available(macOS 26, *), usesGlass {
            return AnyShape(ConcentricRectangle(corners: .concentric(minimum: 10), isUniform: true))
        }
        return AnyShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// The controls' glass in one container, so neighbouring buttons blend as the system's do.
struct PanelGlassGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26, *), PanelLook.usesGlass {
            GlassEffectContainer { content }
        } else {
            content
        }
    }
}

extension View {
    /// A row's padding in a card, a button's or not.
    fileprivate func panelRowPadding() -> some View {
        padding(.horizontal, 10).padding(.vertical, 7)
    }

    /// The glass button styles on macOS 26, bordered ones before; prominent is lime, the app's control color.
    @ViewBuilder func panelButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *), PanelLook.usesGlass {
            if prominent {
                buttonStyle(.glassProminent).tint(Theme.accent).foregroundStyle(Theme.ink)
            } else {
                // Clear of the panel's lime tint: one lime control is the primary action.
                buttonStyle(.glass).tint(nil)
            }
        } else if prominent {
            buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(Theme.ink)
        } else {
            buttonStyle(.bordered).tint(nil)
        }
    }
}
