import SwiftUI

extension Binding where Value == Bool {
    /// Shows an alert, dialog or sheet while `optional` is non-nil; dismissing clears it.
    @MainActor
    init<Wrapped>(isPresenting optional: Binding<Wrapped?>, onDismiss: @escaping @MainActor () -> Void = {}) {
        self.init(
            get: { optional.wrappedValue != nil },
            set: { isPresented in
                if !isPresented {
                    optional.wrappedValue = nil
                    onDismiss()
                }
            })
    }
}
