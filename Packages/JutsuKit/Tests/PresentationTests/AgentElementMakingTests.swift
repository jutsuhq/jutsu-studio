import Foundation
import JutsuAgent
import JutsuCore
import Testing

@testable import Presentation

/// Publishes an element with a new ID, still being checked, unless `fails`; `get` finds it checked.
private struct MakingElements: AccountElements {
    var fails = false
    let created = Box<[String]>([])
    let fetched = Box<[String]>([])

    var owner: String? { "user_1" }

    func elements(after cursor: HistoryCursor?) async throws -> AccountElementPage {
        AccountElementPage(items: [], nextCursor: nil)
    }

    func elementImages(_ element: AccountElement) async throws -> AccountElement {
        fetched.update { $0.append(element.id) }
        let image = ElementImage(url: URL(string: "https://cdn.example.com/1.png")!)
        return AccountElement(id: element.id, name: "Mara-2", category: .prop, images: [image], status: "completed")
    }

    func createElement(name: String, category: ElementCategory, images: [RemoteAsset]) async throws -> AccountElement {
        if fails { throw ProviderError.server(status: 500) }
        created.update { $0.append("\(name) \(category.rawValue) \(images.compactMap(\.id))") }
        return AccountElement(
            id: UUID().uuidString.lowercased(), name: "\(name)-2", category: category, status: "processing")
    }
}

@MainActor
@Suite struct AgentElementMakingTests {
    let requests = AgentRequestGate<AgentCreated, AgentError>(log: AgentRequestLog(folder: nil))
    static let refusals = AgentRequestGate<AgentCreated, AgentError>.Refusals(
        conflict: .requestConflict, unreadable: .agentsOff, neverQueued: .badRequest("never made"))
    static let fields = CreateElementCommand(
        requestID: "el-1", fingerprint: String(repeating: "a", count: 64), name: " Mara ", category: "prop",
        images: ["/tmp/inbox/1/face.png", "/tmp/inbox/2/side.png"])

    fileprivate func making(_ source: MakingElements) -> AgentElementMaking {
        AgentElementMaking(
            requests: requests, source: source,
            upload: { RemoteAsset(url: URL(string: "https://cdn.example.com/u")!, id: $0.fileURL.lastPathComponent) },
            refusals: Self.refusals)
    }

    static func images() -> [LocalImage] {
        fields.images.map { LocalImage(fileURL: URL(filePath: $0)) }
    }

    @Test func anElementIsMadeOnceAndItsRequestSentAgainAnswersWithIt() async throws {
        let source = MakingElements()
        var read = 0
        var discarded = 0
        func create() async throws -> AgentCreated {
            try await making(source).create(
                Self.fields,
                images: {
                    read += 1
                    return Self.images()
                }, discard: { discarded += 1 })
        }

        let made = try await create()
        #expect(source.created.value == ["Mara prop [\"face.png\", \"side.png\"]"])
        let element = try #require(made.element)
        #expect(!made.known && made.jobs.isEmpty)
        #expect(element.name == "Mara-2")
        #expect(element.category == "prop")
        #expect(element.status == "processing")

        let again = try await create()
        #expect(again.known)
        #expect(again.element?.id == element.id)
        #expect(again.element?.status == "completed")
        #expect(again.element?.imageCount == 1)
        #expect(source.fetched.value == [element.id])
        #expect(source.created.value.count == 1)
        #expect(read == 1)
        #expect(discarded >= 2)
    }

    /// Sent before an answer that never came: whether it made the element isn't known, so it isn't sent again.
    @Test func aRequestWhoseAnswerNeverCameIsNeverSentAgain() async throws {
        let source = MakingElements()
        try requests.record(
            Self.fields.requestID, fingerprint: Self.fields.fingerprint, ids: [UUID()], at: .now,
            kind: AgentElementMaking.sentKind)

        await #expect {
            _ = try await making(source).create(Self.fields, images: { Self.images() }, discard: {})
        } throws: { error in
            let error = error as? AgentError
            return error?.code == .failed && error?.retryable == false
                && error?.next?.contains("new request_id") == true
        }
        #expect(source.created.value.isEmpty)
    }

    @Test func aRefusedElementIsForgottenSoTheSameRequestCanBeSentAgain() async throws {
        await #expect {
            _ = try await making(MakingElements(fails: true)).create(
                Self.fields, images: { Self.images() }, discard: {})
        } throws: { error in
            (error as? AgentError)?.retryable == true
        }
        let source = MakingElements()
        let made = try await making(source).create(Self.fields, images: { Self.images() }, discard: {})
        #expect(!made.known)
        #expect(source.created.value.count == 1)
    }

    @Test func theSameRequestIDWithOtherFieldsIsRefused() async throws {
        _ = try await making(MakingElements()).create(Self.fields, images: { Self.images() }, discard: {})
        var other = Self.fields
        other.fingerprint = String(repeating: "b", count: 64)
        await #expect {
            _ = try await making(MakingElements()).create(other, images: { Self.images() }, discard: {})
        } throws: { error in
            (error as? AgentError)?.code == .requestConflict
        }
    }
}
