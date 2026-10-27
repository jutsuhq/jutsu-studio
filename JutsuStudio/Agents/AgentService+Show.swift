import Foundation
import JutsuAgent
import Presentation

// show: a page, a job, or an item's sheet, brought to the front for the person.
extension AgentService {
    func show(_ fields: ShowCommand) async throws(AgentError) -> AgentShown {
        let navigation = environment.navigation
        let shown: AgentShown
        if let item = fields.item, let sheet = fields.sheet {
            shown = try await showSheet(sheet, for: item)
        } else if let id = fields.job, await job(id) == nil, let image = environment.agentImages.record(id) {
            if image.isOver {
                navigation.selection = .library
                shown = AgentShown(page: .library, job: id)
            } else {
                navigation.selection = .queue
                shown = AgentShown(page: .queue, job: id)
            }
        } else if let id = fields.job {
            guard let job = await job(id) else {
                throw AgentError(
                    .notFound, message: "There's no job \(id.uuidString).", retryable: false,
                    next: "Show the queue or the library instead.")
            }
            if job.state == .done {
                navigation.showInLibrary(id)
                shown = AgentShown(page: .library, job: id)
            } else {
                navigation.showInQueue(id)
                shown = AgentShown(page: .queue, job: id)
            }
        } else {
            let page = fields.page ?? .create
            navigation.selection =
                switch page {
                case .create: .create
                case .queue: .queue
                case .library: .library
                case .settings: .settings
                }
            shown = AgentShown(page: page)
        }
        system.showMainWindow()
        return shown
    }
}
