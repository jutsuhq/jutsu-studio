import SwiftUI

/// A titled card of rows with an optional note below (`.set`).
struct SettingsSection<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: () -> Content

    /// A literal title, looked up in the string catalog.
    init(title: LocalizedStringResource, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: String(localized: title), footer: footer, content: content)
    }

    /// A title that is already localized. Disfavored, as in SwiftUI's `Text`, so a literal picks the catalog.
    @_disfavoredOverload
    init(title: String? = nil, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if let title {
                SectionLabel(title: title)
            }
            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, Theme.Spacing.large)
            .card(radius: 14)
            if let footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Spacing.xSmall)
            }
        }
    }
}

/// A label on the left and its control or value on the right, with a hairline above unless it is first.
struct SettingsRow<Control: View>: View {
    let label: String
    var detail: String?
    var isFirst = false
    @ViewBuilder var control: () -> Control

    /// A literal label, looked up in the string catalog.
    init(
        label: LocalizedStringResource, detail: String? = nil, isFirst: Bool = false,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.init(label: String(localized: label), detail: detail, isFirst: isFirst, control: control)
    }

    /// A label that is already localized. Disfavored, as in SwiftUI's `Text`, so a literal picks the catalog.
    @_disfavoredOverload
    init(label: String, detail: String? = nil, isFirst: Bool = false, @ViewBuilder control: @escaping () -> Control) {
        self.label = label
        self.detail = detail
        self.isFirst = isFirst
        self.control = control
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.large) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .hoverHint(detail)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            control()
        }
        .frame(minHeight: 50)
        .overlay(alignment: .top) {
            if !isFirst {
                Rectangle().fill(Theme.stroke).frame(height: 1)
            }
        }
    }
}

extension SettingsRow where Control == Text {
    /// A read-only value.
    init(label: LocalizedStringResource, value: String, isFirst: Bool = false, isMonospaced: Bool = false) {
        self.init(label: String(localized: label), value: value, isFirst: isFirst, isMonospaced: isMonospaced)
    }

    @_disfavoredOverload
    init(label: String, value: String, isFirst: Bool = false, isMonospaced: Bool = false) {
        self.init(label: label, isFirst: isFirst) {
            Text(value)
                .font(.system(size: 13, design: isMonospaced ? .monospaced : .default))
                .foregroundStyle(Theme.muted)
        }
    }
}
