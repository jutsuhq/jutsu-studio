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
        let limit = fields.limit ?? ElementsCommand.defaultLimit
        var cursor = fields.cursor.map(HistoryCursor.init)
        var items: [AgentElement] = []
        for _ in 0..<AgentElementLookup.maxPages {
            let page = try await Self.reading { try await source.elements(after: cursor) }
            items += page.items.filter { AgentElementLookup.matches($0, query: fields.query ?? "", category: category) }
                .map(Self.agentElement)
            cursor = page.nextCursor
            // Whole pages only, so the next cursor never skips an element.
            if cursor == nil || items.count >= limit { break }
        }
        return AgentElementsPage(items: items, nextCursor: cursor?.value)
    }

    /// The elements named, each with all its images, in the order named.
    func namedElements(_ names: [String]) async throws(AgentError) -> [AccountElement] {
        guard !names.isEmpty else { return [] }
        let source = try elementSource()
        var listed: [AccountElement] = []
        var cursor: HistoryCursor?
        var found: [AccountElement] = []
        for _ in 0..<AgentElementLookup.maxPages {
            let page = try await Self.reading { try await source.elements(after: cursor) }
            listed += page.items
            cursor = page.nextCursor
            let ready = names.allSatisfy {
                if case .element = AgentElementLookup.find($0, in: listed) { return true }
                return false
            }
            if cursor == nil || ready { break }
        }
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
