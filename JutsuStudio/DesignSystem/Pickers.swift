import Presentation
import SwiftUI

/// A capsule track with a lime pill on the chosen option (`.seg`). Replaces the system segmented picker,
/// whose separators and accent fill don't match the rest of the app. Segments share the available width;
/// add `.fixedSize()` for a compact control.
struct SegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(selection: Binding<Value>, options: [(value: Value, title: String)]) {
        _selection = selection
        self.options = options
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                SegmentButton(
                    title: option.title, isSelected: option.value == selection, namespace: pill
                ) {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { selection = option.value }
                }
            }
        }
        .padding(3)
        .background(Theme.well, in: Capsule())
        .overlay { Capsule().strokeBorder(Theme.stroke, lineWidth: 1) }
    }
}

extension SegmentedControl where Value: CaseIterable, Value.AllCases: RandomAccessCollection {
    /// One option per case, titled by `title`.
    init(selection: Binding<Value>, title: (Value) -> String) {
        self.init(selection: selection, options: Value.allCases.map { ($0, title($0)) })
    }
}

private struct SegmentButton: View {
    let title: String
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: isSelected ? .bold : .semibold))
                .foregroundStyle(isSelected ? Theme.ink : (isHovered ? Theme.text : Theme.muted))
                .lineLimit(1)
                // Never cut to "Mot…": a segment is at least as wide as its title, and the rest is shared out.
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Theme.accent)
                            .matchedGeometryEffect(id: "pill", in: namespace)
                    } else if isHovered {
                        Capsule().fill(Theme.glass)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A pull-down filter: a capsule with the current choice and a chevron, opening a menu with checkmarks
/// (`.filter`). The label turns lime once a choice other than the first (the "any" option) is picked.
/// Replaces the system pop-up button, whose gray bezel changes shade with focus in the dark toolbar.
struct FilterMenu<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    @State private var isHovered = false

    private var isFiltering: Bool { selection != options.first?.value }
    private var choice: String? { options.first { $0.value == selection }?.title }

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.value) { option in
                    Text(option.title).tag(option.value)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(choice ?? title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isFiltering ? Theme.accent : Theme.faint)
            }
            .foregroundStyle(isFiltering ? Theme.accent : (isHovered ? Theme.text : Theme.muted))
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(isHovered ? Theme.glassHover : Theme.well, in: Capsule())
            .overlay {
                Capsule().strokeBorder(isFiltering ? Theme.accent.opacity(0.5) : Theme.stroke, lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .pointerCursor()
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovered = $0 }
        .motionAnimation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityLabel(title)
        .accessibilityValue(choice ?? "")
    }
}

/// An on-or-off filter, as a capsule like `FilterMenu`'s that turns lime while on: a two-way choice needs no menu.
struct FilterToggle: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool
    @State private var isHovered = false

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? Theme.accent : (isHovered ? Theme.text : Theme.muted))
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(isHovered ? Theme.glassHover : Theme.well, in: Capsule())
            .overlay {
                Capsule().strokeBorder(isOn ? Theme.accent.opacity(0.5) : Theme.stroke, lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .fixedSize()
        .onHover { isHovered = $0 }
        .motionAnimation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// A capsule search field with a magnifier and a clear button (`.search`). ⌘F focuses it.
struct SearchField: View {
    @Binding var text: String
    let prompt: String
    @FocusState private var isFocused: Bool
    @StoredShortcut(.find) private var findShortcut

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isFocused ? Theme.accent : Theme.faint)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .hoverHint("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Theme.well, in: Capsule())
        .overlay {
            Capsule().strokeBorder(isFocused ? Theme.accent : Theme.stroke, lineWidth: isFocused ? 1.5 : 1)
        }
        .focusEffectDisabled()
        .motionAnimation(.easeOut(duration: 0.15), value: isFocused)
        .background {
            Button("Find") { isFocused = true }
                .keyboardShortcut(findShortcut)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}
