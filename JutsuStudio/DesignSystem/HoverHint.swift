import AppKit
import SwiftUI

/// The app's tooltip: a small styled hint just under a control while it is hovered, used everywhere in place of
/// `.help` (menu items keep `.help`, which only the system can show there). Unlike `.help`, it shows sooner and
/// survives a parent that redraws, as a queue row with a running timer or Create's form does, which keeps resetting
/// the system tooltip. It lives in its own borderless window, so a scroll view or a neighbouring control never clips or
/// covers it, and it stays inside the app window.
private struct HoverHintModifier: ViewModifier {
    /// `nil` shows no hint.
    let text: Text?
    @State private var id = UUID()
    @State private var anchor = HintAnchor.Box()
    @State private var frame = CGRect.zero
    @State private var delay: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .background(HintAnchor(box: anchor))
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: { newFrame in
                // The control moved, as when its list scrolls: the hint would point at nothing.
                if newFrame != frame { HintWindow.shared.hide(for: id) }
                frame = newFrame
            }
            .onHover { isInside in
                delay?.cancel()
                guard isInside, let text else {
                    HintWindow.shared.hide(for: id)
                    return
                }
                delay = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    HintWindow.shared.show(text, under: anchor.view, for: id)
                }
            }
            .onDisappear {
                delay?.cancel()
                HintWindow.shared.hide(for: id)
            }
            .accessibilityHint(text ?? Text(verbatim: ""))
    }
}

/// An empty AppKit view behind the control: its window and frame place the hint, in a toolbar or a sheet as well.
private struct HintAnchor: NSViewRepresentable {
    final class Box {
        weak var view: NSView?
    }

    let box: Box

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { box.view = view }
}

/// The one hint on screen: a child window of the control's window, so it moves and orders with it.
@MainActor private final class HintWindow {
    static let shared = HintWindow()

    private static let gap: CGFloat = 6
    private static let margin: CGFloat = 8

    private let panel: NSPanel
    private let host = NSHostingView(rootView: HintBubble(text: Text(verbatim: "")))
    private var owner: UUID?

    private init() {
        panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = host
    }

    /// Shows `text` centered under `anchor`, moved in from the window's sides, and above the control when there is
    /// no room below.
    func show(_ text: Text, under anchor: NSView?, for id: UUID) {
        guard let anchor, let window = anchor.window else { return }
        host.rootView = HintBubble(text: text)
        let size = host.fittingSize
        let control = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))

        var origin = CGPoint(x: control.midX - size.width / 2, y: control.minY - Self.gap - size.height)
        origin.x = min(max(origin.x, window.frame.minX + Self.margin), window.frame.maxX - Self.margin - size.width)
        if origin.y < window.frame.minY + Self.margin { origin.y = control.maxY + Self.gap }

        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        owner = id
    }

    /// Hides the hint if `id`'s control is the one showing it.
    func hide(for id: UUID) {
        guard owner == id else { return }
        owner = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

private struct HintBubble: View {
    let text: Text

    var body: some View {
        text
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.text)
            .lineLimit(5)
            .frame(maxWidth: 280, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Theme.glassStroke, lineWidth: 1)
            }
            .fixedSize()
            .environment(\.colorScheme, .dark)
    }
}

extension View {
    /// The app's tooltip (`HoverHintModifier`); an empty text shows none.
    func hoverHint<S: StringProtocol>(_ text: S) -> some View {
        modifier(HoverHintModifier(text: text.isEmpty ? nil : Text(text)))
    }

    /// The app's tooltip (`HoverHintModifier`), localized like `.help("…")`.
    func hoverHint(_ key: LocalizedStringKey) -> some View {
        modifier(HoverHintModifier(text: Text(key)))
    }

    func hoverHint(_ text: Text) -> some View {
        modifier(HoverHintModifier(text: text))
    }
}
