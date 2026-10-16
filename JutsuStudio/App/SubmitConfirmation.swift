import Presentation
import SwiftUI

extension View {
    /// The over-cap question of `controller`'s submits, while one is up. Confirming queues its jobs with the cap
    /// approved, as a submit of its own, so leaving the screen doesn't cancel it.
    /// - Parameter confirmTitle: the confirm button's title; the confirmation's own without one.
    func submitConfirmation(
        _ controller: SubmitController, confirmTitle: String? = nil, titleVisibility: Visibility = .visible
    ) -> some View {
        @Bindable var controller = controller
        return confirmationDialog(
            controller.pending?.confirmation.title ?? "", isPresented: Binding(isPresenting: $controller.pending),
            titleVisibility: titleVisibility, presenting: controller.pending
        ) { pending in
            Button(confirmTitle ?? pending.confirmation.confirmTitle) { controller.confirm(pending) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.confirmation.message)
        }
    }
}
