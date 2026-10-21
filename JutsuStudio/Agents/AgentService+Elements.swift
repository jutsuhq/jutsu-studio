import Foundation
import HiggsfieldProviders
import JutsuAgent
import JutsuCore
import Presentation
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "Agents")

// elements, and the elements create_video, quote and create_image take by name: References › From Higgsfield's own
// source (`accountElements`) and download (`downloadElementImage`), read-only and free.
extension AgentService {
    func elements(_ fields: ElementsCommand) async throws(AgentError) -> AgentElementsPage {
        let source = try elementSource()
        let category = fields.category.flatMap(ElementCategory.init(rawValue:))
        let (items, next) = try await Self.reading {
            try await AgentElementLookup.page(
                in: source, query: fields.query ?? "", category: category,
                limit: fields.limit ?? ElementsCommand.defaultLimit, after: fields.cursor.map(HistoryCursor.init))
        }
        return AgentElementsPage(items: items.map(Self.agentElement), nextCursor: next?.value)
    }

    /// The elements named, each with all its images, in the order named. Every page is read first, so a name two
    /// elements share is refused however far apart they are listed.
    func namedElements(_ names: [String]) async throws(AgentError) -> [AccountElement] {
        guard !names.isEmpty else { return [] }
        let source = try elementSource()
        let listed = try await Self.reading { try await AgentElementLookup.all(in: source) }
        var found: [AccountElement] = []
        for name in names {
            switch AgentElementLookup.find(name, in: listed) {
            case .element(let element):
                found.append(
                    element.images.isEmpty
                        ? try await Self.reading { try await source.elementImages(element) } : element)
            case .ambiguous(let count):
                throw .invalidRequest(
                    "\(count) elements are named \(name); ask the person to rename one, or name another element.")
            case .missing:
                throw AgentError(
                    .notFound, message: "The account has no element named \(name).", retryable: false,
                    next: "Call elements for the names.")
            }
        }
        return found
    }

    /// The images of the elements named, downloaded once each as From Higgsfield adds them.
    func elementImages(_ names: [String]) async throws(AgentError) -> [(name: String, images: [LocalImage])] {
        var result: [(name: String, images: [LocalImage])] = []
        for element in try await namedElements(names) {
            guard !element.images.isEmpty else {
                throw .invalidRequest("The element \(element.name) has no images to use.")
            }
            var images: [LocalImage] = []
            for (index, image) in element.images.enumerated() {
                images.append(
                    try await Self.reading { try await environment.downloadElementImage(image, at: index, of: element) }
                )
            }
            result.append((element.name, images))
        }
        return result
    }

    /// The references answer of a request: every image in the order sent, with its tag.
    static func references(
        elements: [(name: String, images: [LocalImage])], files: [LocalImage]
    ) -> [AgentReference]? {
        let references = AgentElementLookup.references(elements: elements, files: files)
        guard !references.isEmpty else { return nil }
        return references.map {
            AgentReference(tag: $0.tag, element: $0.element, file: $0.image.fileURL.path(percentEncoded: false))
        }
    }

    private func elementSource() throws(AgentError) -> any AccountElements {
        guard let source = environment.accountElements, HiggsfieldMCPProvider.offersReferenceElements else {
            throw AgentError(
                .notApplicable, message: "Reference elements need a Higgsfield account connection.",
                retryable: false, next: "Ask the person to connect a Higgsfield account in Settings.")
        }
        return source
    }

    private static func agentElement(_ element: AccountElement) -> AgentElement {
        AgentElement(
            id: element.id, name: element.name, category: element.category?.rawValue,
            imageCount: element.images.isEmpty ? nil : element.images.count)
    }

    /// A call to the account, its failure as an agent error.
    private static func reading<T>(_ body: () async throws -> T) async throws(AgentError) -> T {
        do {
            return try await body()
        } catch {
            logger.error("Can't read the account's elements: \(String(describing: error), privacy: .private)")
            throw AgentError(
                .failed, message: "Higgsfield didn't return the account's elements: \(error.localizedDescription)",
                retryable: true, next: "Try again in a moment.")
        }
    }
}
