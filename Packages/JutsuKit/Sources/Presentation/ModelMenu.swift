import Foundation
import JutsuCore

/// One model of the picker: "Kling O3", "$0.126 / s · up to 10 s".
public struct ModelMenuRow: Sendable, Hashable, Identifiable {
    public var model: VideoModel
    public var title: String
    /// `nil` when there is nothing to tell the models apart by.
    public var detail: String?

    public var id: String { model.rawValue }
}

extension CreateForm {
    /// The models the picker offers for the mode (`modelOptions`), in the catalog's order, as one flat list. Each row
    /// says what a second costs on that model with the form's inputs, at the resolution it would run at (none for
    /// credits, which have no rate table), and the longest the mode takes on it, but only when the models' longest
    /// lengths differ: "up to 30 s" on every row tells nothing.
    public func modelMenu(in context: CreateContext) -> [ModelMenuRow] {
        let rows = modelOptions(in: context).map { model in
            var form = self
            form.model = model
            return (model, form.rateText(in: context), form.limits.duration.upperBound)
        }
        let showsLength = Set(rows.map(\.2)).count > 1
        return rows.map { model, rate, longest in
            let length = String(localized: "up to \(CostText.limit(longest))", bundle: .module)
            let parts = [rate, showsLength ? length : nil].compactMap(\.self)
            return ModelMenuRow(
                model: model, title: model.title, detail: parts.isEmpty ? nil : parts.joined(separator: " · "))
        }
    }
}
