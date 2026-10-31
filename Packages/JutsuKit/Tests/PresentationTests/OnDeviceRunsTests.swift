import Foundation
import JutsuCore
import JutsuTestSupport
import Testing

@testable import Presentation

/// Writes a stand-in result and waits until released; stops when canceled, deleting what it wrote as the engine does.
/// Notes each question about a model, and whether it was asked on the main thread.
final class FakeOnDeviceEngine: OnDeviceEnhancing, @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private var released = false
    private var _mostAtOnce = 0
    private var _started: [URL] = []
    private var _modelChecks: [(engine: OnDeviceEngine, onMain: Bool)] = []
    var failure: (any Error)?
    var supported: Set<OnDeviceEngine> = Set(OnDeviceEngine.allCases)
    var readyModels: Set<OnDeviceEngine> = []

    var modelChecks: [(engine: OnDeviceEngine, onMain: Bool)] { lock.withLock { _modelChecks } }

    func modelIsReady(_ engine: OnDeviceEngine) -> Bool {
        lock.withLock { _modelChecks.append((engine, Thread.isMainThread)) }
        return readyModels.contains(engine)
    }

    var mostAtOnce: Int { lock.withLock { _mostAtOnce } }
    var started: [URL] { lock.withLock { _started } }
    var isRunning: Bool { lock.withLock { running > 0 } }

    func release() { lock.withLock { released = true } }

    func supports(_ engine: OnDeviceEngine) -> Bool { supported.contains(engine) }

    func run(
        _ action: OnDeviceAction, on source: URL, to output: URL,
        progress: @escaping @Sendable (OnDeviceProgress) -> Void
    ) async throws -> OnDeviceOutput {
        lock.withLock {
            running += 1
            _mostAtOnce = max(_mostAtOnce, running)
            _started.append(source)
        }
        defer { lock.withLock { running -= 1 } }
        do {
            try Data("frames".utf8).write(to: output)
            progress(.working(0.5))
            while !lock.withLock({ released }) { try await Task.sleep(for: .milliseconds(2)) }
            if let failure { throw failure }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return OnDeviceOutput(pixelSize: PixelSize(width: 640, height: 360), duration: 2, fileExtension: "mp4")
    }
}

@MainActor
@Suite struct OnDeviceRunsTests {
    struct Registered: Equatable {
        let source: MaterialReference
        let file: URL
    }

    struct Refused: Error {}

    let folder = FileManager.default.temporaryDirectory.appending(path: "OnDeviceRuns-\(UUID())")
    let engine = FakeOnDeviceEngine()
    let consent: OnDeviceModelConsent

    init() throws {
        let name = "OnDeviceRunsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        consent = OnDeviceModelConsent(defaults: defaults)
    }

    private func request(
        _ name: String = "rooftop.mp4", action: OnDeviceAction = .smoothMotion(.fps60)
    ) -> OnDeviceRuns.Request {
        OnDeviceRuns.Request(
            source: MaterialReference(materialID: UUID(), versionID: UUID()),
            file: folder.appending(path: name), action: action,
            destination: folder.appending(path: "Videos"), scratch: folder.appending(path: "Videos"))
    }

    private func files() -> [String] {
        let videos = folder.appending(path: "Videos")
        return ((try? FileManager.default.contentsOfDirectory(atPath: videos.path)) ?? []).sorted()
    }

    @Test func runsOneAtATimeAndAddsEachResultAsANewVersion() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        var registered: [Registered] = []
        let runs = OnDeviceRuns(engine: engine, consent: consent) { request, file, output in
            #expect(output.outputMedia == OutputMedia(duration: 2, pixelSize: PixelSize(width: 640, height: 360)))
            registered.append(Registered(source: request.source, file: file))
        }
        let first = request()
        let second = request()

        runs.start(first)
        runs.start(second)
        await eventually { runs.runs.first?.state == .working(0.5) }
        #expect(runs.runs.map(\.state) == [.working(0.5), .waiting])
        #expect(runs.run(for: second.source.materialID)?.state == .waiting)
        engine.release()
        await runs.finish()

        #expect(engine.mostAtOnce == 1)
        #expect(registered.map(\.source) == [first.source, second.source])
        #expect(files() == ["rooftop 60fps 2.mp4", "rooftop 60fps.mp4"])
        #expect(runs.runs.isEmpty)
        #expect(runs.failure == nil)
    }

    @Test func aSecondRunOnTheSameItemIsRefused() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let runs = OnDeviceRuns(engine: engine, consent: consent) { _, _, _ in }
        let first = request()
        var second = request(action: .smoothMotion(.slowMotion2x))
        second.source = first.source

        #expect(runs.start(first))
        #expect(!runs.start(second))
        #expect(runs.runs.count == 1)
        engine.release()
        await runs.finish()
        #expect(runs.start(second))
        await runs.finish()
    }

    @Test func leftoversOfEarlierRunsGoAtLaunchAndNothingElse() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let videos = folder.appending(path: "Videos")
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        let names = [OnDeviceRuns.partialName(UUID()), ".\(UUID().uuidString).partial", "rooftop.mp4"]
        for name in names { try Data("x".utf8).write(to: videos.appending(path: name)) }

        OnDeviceRuns.removeLeftovers(in: videos)

        #expect(files() == Array(names.dropFirst()).sorted())
    }

    @Test func cancelingTheRunningRunLeavesNoFile() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        var registered = 0
        let runs = OnDeviceRuns(engine: engine, consent: consent) { _, _, _ in registered += 1 }

        runs.start(request())
        await eventually { engine.isRunning }
        runs.cancel(try #require(runs.runs.first).id)
        await runs.finish()

        #expect(registered == 0)
        #expect(files().isEmpty)
        #expect(runs.failure == nil)
        #expect(runs.runs.isEmpty)
    }

    @Test func cancelingAWaitingRunDropsIt() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let runs = OnDeviceRuns(engine: engine, consent: consent) { _, _, _ in }
        let first = request("first.mp4")

        runs.start(first)
        runs.start(request("second.mp4"))
        runs.cancel(try #require(runs.runs.last).id)
        engine.release()
        await runs.finish()

        #expect(engine.started == [first.file])
        #expect(files() == ["first 60fps.mp4"])
    }

    @Test func aFailedRunIsReportedAndLeavesNoFile() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        engine.failure = Refused()
        engine.release()
        let runs = OnDeviceRuns(engine: engine, consent: consent) { _, _, _ in
            Issue.record("A failed run was registered")
        }

        runs.start(request())
        await runs.finish()

        #expect(runs.failure?.title == "Can't finish Smooth Motion to 60 fps")
        #expect(files().isEmpty)
    }

    @Test func aResultTheCatalogRefusesIsTakenBack() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        engine.release()
        let runs = OnDeviceRuns(engine: engine, consent: consent) { _, _, _ in throw Refused() }

        runs.start(request())
        await runs.finish()

        #expect(runs.failure != nil)
        #expect(files().isEmpty)
    }

    @Test func anUpscaleWaitsForConsentToTheModelDownload() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        engine.release()
        let runs = OnDeviceRuns(engine: engine, consent: consent) { _, _, _ in }

        #expect(runs.needsConsent(.videoSuperResolution))
        #expect(!runs.needsConsent(.frameRateConversion))
        #expect(!runs.start(request(action: .upscaleVideo(.full))))
        #expect(runs.runs.isEmpty)
        #expect(engine.started.isEmpty)

        runs.agree(to: .videoSuperResolution)
        #expect(runs.start(request(action: .upscaleVideo(.full))))
        await runs.finish()

        #expect(files() == ["rooftop 4x.mp4"])
        // Remembered for the next run, and the next launch.
        #expect(!OnDeviceRuns(engine: engine, consent: consent) { _, _, _ in }.needsConsent(.videoSuperResolution))
        // Each kind has a model of its own, asked about on its own.
        #expect(runs.needsConsent(.imageSuperResolution))
        #expect(!runs.start(request("portrait.png", action: .upscaleImage(.full))))
    }

    @Test func onlyAnImageUpTo1080pIsOfferedAnUpscale() {
        let all: (OnDeviceEngine) -> Bool = { _ in true }
        #expect(OnDeviceOffer.upscalesImage(PixelSize(width: 1920, height: 1080), supports: all))
        #expect(OnDeviceOffer.upscalesImage(PixelSize(width: 1080, height: 1920), supports: all))
        #expect(!OnDeviceOffer.upscalesImage(PixelSize(width: 2048, height: 1080), supports: all))
        #expect(!OnDeviceOffer.upscalesImage(nil, supports: all))
        #expect(
            !OnDeviceOffer.upscalesImage(
                PixelSize(width: 1024, height: 1024), supports: { $0 != .imageSuperResolution }))
    }

    @Test func onlyAResultWithItsFileHereIsOffered() {
        var job = JobFixture.job(.done)
        job.outputFile = URL(fileURLWithPath: "/tmp/rooftop.mp4")
        let item = LibraryItemModel(job: job)

        #expect(OnDeviceOffer.of(item, supports: { _ in true }).smoothMotion)
        #expect(OnDeviceOffer.of(item, supports: { _ in false }).isEmpty)
        // The fixture's result is 720p.
        #expect(OnDeviceOffer.of(item, supports: { _ in true }).upscaleVideo)
        job.outputMedia = OutputMedia(duration: 5, pixelSize: PixelSize(width: 1920, height: 1080))
        #expect(!OnDeviceOffer.of(LibraryItemModel(job: job), supports: { _ in true }).upscaleVideo)
        job.outputMedia = OutputMedia(duration: 5, pixelSize: PixelSize(width: 720, height: 1280))
        #expect(OnDeviceOffer.of(LibraryItemModel(job: job), supports: { _ in true }).upscaleVideo)
        job.outputFile = nil
        #expect(OnDeviceOffer.of(LibraryItemModel(job: job), supports: { _ in true }).isEmpty)
    }

    @Test func progressReadsAsTheActionAndItsPercent() {
        let run = OnDeviceRuns.Run(id: UUID(), request: request(), state: .working(0.42))
        CostText.$locale.withValue(.enUS) {
            #expect(OnDeviceText.progress(of: run) == "Smooth Motion to 60 fps · 42%")
        }
    }
}
