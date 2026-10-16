import JutsuCore
import Presentation
import SwiftUI

extension View {
    /// Queues `request` as a new job, with its own id and idempotency key, once it is set. Over today's
    /// spend cap it asks first, as Create does. A blocked duplicate isn't queued; its reason and any error go
    /// to the connection alert.
    func duplicating(_ request: Binding<JobSpec?>) -> some View {
        modifier(DuplicateJob(request: request))
    }
}

private struct DuplicateJob: ViewModifier {
    @Binding var request: JobSpec?

    @Environment(AppEnvironment.self) private var environment
    @Environment(ConnectionStore.self) private var connection
    /// A second click while one duplicate is being queued is dropped, so it can't queue another paid job.
    @State private var submitting = SubmitController()

    func body(content: Content) -> some View {
        content
            // In a submit of its own, not the view's task: leaving the Queue mustn't cancel a duplicate halfway
            // through queueing it.
            .onChange(of: request, initial: true) { _, spec in
                guard let spec else { return }
                request = nil
                duplicate(spec)
            }
            .submitConfirmation(submitting)
    }

    private func duplicate(_ spec: JobSpec) {
        let submitting = submitting
        submitting.run {
            await submitting.handle(
                await environment.submitDecision(for: spec),
                blocked: { reason in
                    connection.alert = UserMessage(
                        title: String(localized: "Can't duplicate this job"), message: reason)
                }
            ) { specs, approved in
                if let error = await pipeline.enqueue(specs, overCapApproved: approved) {
                    connection.alert = error
                }
            }
        }
    }

    private var pipeline: SubmitPipeline {
        SubmitPipeline(environment: environment, connection: connection)
    }
}
