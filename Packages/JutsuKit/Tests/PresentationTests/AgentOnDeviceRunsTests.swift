import Foundation
import JutsuAgent
import JutsuCore
import JutsuTestSupport
import Testing

@testable import Presentation

/// enhance on this Mac for agents, with a stand-in engine: once per request ID, refused by the sheet's rules, followed
/// and canceled as a job of kind on_device.
@MainActor
@Suite struct AgentOnDeviceRunsTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "AgentOnDevice-\(UUID())")
    let engine = FakeOnDeviceEngine()
    let consent: OnDeviceModelConsent
    let runs: OnDeviceRuns
    let agent: AgentOnDeviceRuns
    let gate = AgentRequestGate<AgentCreated, AgentError>(log: AgentRequestLog(folder: nil))
    let refusals = AgentRequestGate<AgentCreated, AgentError>.Refusals(
        conflict: .requestConflict, unreadable: AgentError(.failed, message: "unreadable", retryable: true),
        neverQueued: AgentError(.failed, message: "never queued", retryable: true))
    let source = MaterialReference(materialID: UUID(), versionID: UUID())

    init() throws {
        let name = "AgentOnDeviceRunsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        consent = OnDeviceModelConsent(defaults: defaults)
        runs = OnDeviceRuns(engine: engine, consent: consent) { _, _, _ in }
        agent = AgentOnDeviceRuns(runs: runs) { .credits }
    }

    private func command(
        _ operation: AgentEnhancement = .smoothMotion, mode: String? = "slow_2x", engine: String? = nil,
        requestID: String = "run-1", fingerprint: String = String(repeating: "a", count: 64)
    ) -> EnhanceCommand {
        EnhanceCommand(
            requestID: requestID, fingerprint: fingerprint, item: source.materialID, operation: operation,
            engine: engine, mode: mode, maxCost: nil)
    }

    private func video(
        _ size: PixelSize = PixelSize(width: 854, height: 480), rate: Double = 30
    )
        -> AgentOnDeviceRuns
        .Target
    {
        target(.video(size, frameRate: rate, duration: 4))
    }

    private func target(_ media: AgentOnDeviceMedia) -> AgentOnDeviceRuns.Target {
        AgentOnDeviceRuns.Target(
            source: source, file: folder.appending(path: "rooftop.mp4"), media: media,
            destination: folder.appending(path: "Videos"), scratch: folder.appending(path: "Videos"))
    }

    private func enhance(
        _ fields: EnhanceCommand, on target: AgentOnDeviceRuns.Target? = nil, recorded: Box<[UUID]> = Box([])
    ) async throws(AgentError) -> AgentCreated {
        let target = target ?? video()
        let gate = gate
        return try await agent.enhance(
            fields, client: "agent", gate: gate, refusals: refusals,
            record: { ids throws(AgentError) in
                recorded.update { $0 += ids }
                do {
                    try gate.record(
                        fields.requestID, fingerprint: fields.fingerprint, ids: ids, at: .now,
                        kind: AgentOnDeviceRuns.kind)
                } catch {
                    throw AgentError(.failed, message: "can't record", retryable: true)
                }
            },
            target: { target })
    }

    private func refusal(_ fields: EnhanceCommand, on target: AgentOnDeviceRuns.Target? = nil) async -> AgentError? {
        do {
            _ = try await enhance(fields, on: target)
            return nil
        } catch {
            return error
        }
    }

    @Test func theSameRequestStartsOneRunAndAnswersWithIt() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorded = Box<[UUID]>([])
        let first = try await enhance(command(), recorded: recorded)
        let again = try await enhance(command(), recorded: recorded)

        #expect(!first.known && again.known)
        #expect(first.jobs.map(\.id) == again.jobs.map(\.id) && recorded.value == first.jobs.map(\.id))
        #expect(runs.runs.count == 1)
        let job = try #require(first.jobs.first)
        #expect(job.kind == "on_device" && job.operation == "smooth_motion" && job.mode == "slow_2x")
        #expect(job.item == source.materialID && job.requestID == "run-1" && job.client == "agent")
        #expect(job.price == AgentAmount(0, .credits) && job.isPriceExact && !job.charged)
        #expect((job.estimatedSeconds ?? 0) > 0)
        // The same ID with other parameters is another request.
        let other = command(mode: "slow_4x", fingerprint: String(repeating: "b", count: 64))
        #expect(await refusal(other)?.code == .requestConflict)
        engine.release()
        await runs.finish()
    }

    @Test func jobsFollowARunUntilItsResultIsIn() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try #require(try await enhance(command()).jobs.first?.id)
        await eventually { agent.job(id)?.progress == 0.5 }
        #expect(agent.job(id)?.state == "processing" && !agent.isSettled(id))
        #expect(agent.started.map { $0.id } == [id])

        engine.release()
        await runs.finish()

        let done = try #require(agent.job(id))
        #expect(done.state == "done" && agent.isSettled(id) && done.finishedAt != nil)
        #expect(done.result?.hasSuffix("rooftop slow 2x.mp4") == true)
        #expect(done.item == source.materialID)
        // A known request answers with the finished run, and starts nothing.
        let again = try await enhance(command())
        #expect(again.known && again.jobs.first?.state == "done" && runs.runs.isEmpty)
    }

    @Test func cancelStopsTheRunAndLeavesNoFile() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try #require(try await enhance(command()).jobs.first?.id)
        await eventually { engine.isRunning }

        let canceled = try await agent.cancel(id)

        #expect(canceled?.state == "canceled")
        #expect(
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "Videos").path)) ?? [])
                .isEmpty)
        #expect(try await agent.cancel(UUID()) == nil)
    }

    @Test func thePersonsOwnRunIsShownButNotCanceled() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = OnDeviceRuns.Request(
            source: source, file: folder.appending(path: "rooftop.mp4"), action: .smoothMotion(.fps60),
            destination: folder.appending(path: "Videos"), scratch: folder.appending(path: "Videos"))
        let id = UUID()
        runs.start(request, id: id)

        #expect(agent.job(id)?.requestID == nil && agent.job(id)?.mode == "60fps")
        await #expect(throws: AgentError.self) { try await agent.cancel(id) }
        #expect(agent.started.isEmpty)
        engine.release()
        await runs.finish()
    }

    @Test func aMacWithoutTheEngineIsRefused() async {
        engine.supported = []
        #expect(await refusal(command())?.code == .engineUnavailable)
        #expect(await refusal(command(.upscale, mode: nil, engine: "mac"))?.code == .engineUnavailable)
        #expect(runs.runs.isEmpty)
    }

    @Test func aSourceTooLargeIsRefusedWithItsLimit() async {
        consent.agree(to: .videoSuperResolution)
        consent.agree(to: .imageSuperResolution)
        let upscale = command(.upscale, mode: nil, engine: "mac")
        let large = await refusal(upscale, on: video(PixelSize(width: 1920, height: 1080)))
        #expect(large?.code == .invalidRequest)
        #expect(large?.message.contains("1280×720") == true && large?.message.contains("1920×1080") == true)
        let image = await refusal(upscale, on: target(.image(PixelSize(width: 2000, height: 1000))))
        #expect(image?.message.contains("images up to 1920×1080") == true)
        #expect(await refusal(command(mode: "60fps"), on: video(rate: 60))?.next == "Use mode slow_2x or slow_4x.")
        #expect(await refusal(command(), on: target(.unreadableVideo))?.code == .failed)
        #expect(await refusal(command(), on: target(.image(PixelSize(width: 10, height: 10))))?.code == .invalidRequest)
        #expect(runs.runs.isEmpty)
    }

    @Test func anItemWithARunGoingIsBusyAndSaysWhichRun() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try #require(try await enhance(command()).jobs.first?.id)
        let busy = await refusal(command(requestID: "run-2"))

        #expect(busy?.code == .busy && busy?.retryable == true)
        #expect(busy?.message.contains(first.uuidString) == true && busy?.next?.contains(first.uuidString) == true)
        #expect(runs.runs.count == 1)
        engine.release()
        await runs.finish()
    }

    @Test func anUpscaleBeforeTheModelConsentNeedsThePerson() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let upscale = command(.upscale, mode: nil, engine: "mac")
        let waiting = await refusal(upscale)

        #expect(waiting?.code == .needsPerson)
        #expect(
            waiting?.next?.contains("show with item \(source.materialID.uuidString) and sheet upscale_on_mac") == true)
        #expect(runs.runs.isEmpty)
        #expect(agent.capabilities().upscaleVideo.model == "needs_consent")
        // Smooth Motion has no model to agree to.
        #expect(agent.capabilities().smoothMotion.model == "none")
        consent.agree(to: .videoSuperResolution)
        #expect(agent.capabilities().upscaleVideo.model == "agreed")
        let started = try await enhance(upscale)
        #expect(started.jobs.first?.operation == "upscale" && started.jobs.first?.mode == nil)
        engine.release()
        await runs.finish()
    }

    @Test func aKnownRequestAfterARelaunchAnswersItsRunAsForgottenAndStartsNothing() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try #require(try await enhance(command()).jobs.first?.id)
        engine.release()
        await runs.finish()
        #expect(gate.kind(of: id) == AgentOnDeviceRuns.kind)

        // A relaunch forgets the runs; the request log stays.
        let relaunched = OnDeviceRuns(engine: engine, consent: consent) { _, _, _ in }
        let relaunchedAgent = AgentOnDeviceRuns(runs: relaunched) { .credits }
        let target = video()
        let again = try await relaunchedAgent.enhance(
            command(), client: "agent", gate: gate, refusals: refusals,
            record: { _ throws(AgentError) in Issue.record("recorded again") }, target: { target })

        #expect(again.known && again.jobs.map(\.id) == [id])
        #expect(again.jobs.first?.state == "unknown" && again.jobs.first?.kind == AgentOnDeviceRuns.kind)
        #expect(again.jobs.first == AgentOnDeviceRuns.forgotten(id))
        #expect(relaunched.runs.isEmpty && relaunchedAgent.job(id) == nil && !relaunchedAgent.knows(id))
    }

    @Test func theModelIsAskedAboutOnlyAfterARunAndOffTheMainActor() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        engine.readyModels = [.videoSuperResolution]
        #expect(agent.capabilities().upscaleVideo.model == "needs_consent")
        consent.agree(to: .videoSuperResolution)
        #expect(agent.capabilities().upscaleVideo.model == "agreed")
        #expect(engine.modelChecks.isEmpty)

        _ = try await enhance(command(.upscale, mode: nil, engine: "mac"))
        engine.release()
        await runs.finish()

        await eventually { agent.capabilities().upscaleVideo.model == "ready" }
        #expect(engine.modelChecks.map(\.engine) == [.videoSuperResolution])
        #expect(engine.modelChecks.allSatisfy { !$0.onMain })
        // Never asked about an engine the person hasn't agreed to, nor about Smooth Motion's, which has none.
        #expect(agent.capabilities().upscaleImage.model == "needs_consent")
        #expect(engine.modelChecks.count == 1)
    }

    @Test func theEnginesAreReportedWithTheirLimits() {
        engine.supported = [.frameRateConversion]
        let engines = agent.capabilities()
        #expect(engines.smoothMotion.available && !engines.upscaleVideo.available)
        #expect(engines.upscaleVideo.maxLongSide == 1280 && engines.upscaleVideo.maxShortSide == 720)
        #expect(engines.upscaleImage.maxLongSide == 1920 && engines.upscaleImage.maxShortSide == 1080)
        #expect(engines.smoothMotion.maxLongSide == nil)
    }
}
