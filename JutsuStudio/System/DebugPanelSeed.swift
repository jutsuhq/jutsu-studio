#if DEBUG
    import Foundation
    import JutsuAgent
    import JutsuCore
    import Presentation

    /// Made-up states of the menu bar panel for checking its design (`DebugLaunchHooks.panelVariable`), compiled into
    /// Debug builds only. Its jobs go into `LiveJobs` alone, never to the engine, so nothing is sent or charged.
    enum DebugPanelSeed {
        enum State: String {
            case idle, running, needs, recent, all

            var runs: Bool { self == .running || self == .all }
            var needs: Bool { self == .needs || self == .all }
            var recent: Bool { self == .recent || self == .all }
        }

        static func jobs(_ state: State, media: URL?) -> [Job] {
            let now = Date.now
            var jobs: [Job] = []
            if state.runs {
                jobs.append(job("rooftop chase", .motionTransfer, .uploading, progress: 0.62, minutesAgo: 4, now: now))
                var generating = job("neon alley", .restyle, .processing, minutesAgo: 6, now: now)
                generating.submittedAt = now.addingTimeInterval(-70)
                generating.processingAt = now.addingTimeInterval(-60)
                jobs.append(generating)
                var waiting = job("street dance", .motionTransfer, .waitingForSlot, minutesAgo: 2, now: now)
                waiting.agent = origin(hold: nil)
                jobs.append(waiting)
            }
            if state.needs {
                var held = job("product spin", .objectSwap, .paused(.agentLimit), minutesAgo: 3, now: now)
                held.agent = origin(hold: .overDailyBudget)
                jobs.append(held)
                jobs.append(job("beach intro", .edit, .paused(.insufficientFunds), minutesAgo: 9, now: now))
            }
            if state.recent {
                for (index, name) in ["sunset drive", "studio portrait", "city timelapse"].enumerated() {
                    var done = job(name, .restyle, .done, minutesAgo: Double(20 + index * 15), now: now)
                    done.finishedAt = now.addingTimeInterval(-Double(2 + index * 14) * 60)
                    done.outputFile = media
                    jobs.append(done)
                }
            }
            return jobs
        }

        static func runs(_ state: State) -> [MenuBarPanel.Run] {
            guard state.runs else { return [] }
            return [
                MenuBarPanel.Run(
                    id: UUID(), kind: .onDevice, title: "skate park", detail: "Upscale 4× · 38%", fraction: 0.38),
                MenuBarPanel.Run(
                    id: UUID(), kind: .subtitles, title: "interview", detail: "Making subtitles · 71%",
                    fraction: 0.71),
            ]
        }

        static func agents(_ state: State) -> MenuBarPanel.AgentsInput {
            var activity = AgentActivity()
            activity.noteRequest(from: "claude-code", at: .now)
            if state.needs {
                activity.noteRequest(from: "codex", at: .now)
                activity.noteAsk(
                    AgentActivity.Ask(item: UUID(), sheet: .upscaleOnMac, title: "mountain flyover", askedAt: .now))
            }
            let budget = AgentCapabilities.Budget(
                unit: .usdCents, dailyLimit: 2500, spentToday: state == .idle ? 0 : 1240,
                reservedToday: state.runs ? 310 : 0, remaining: state == .idle ? 2500 : 950, dailyCap: 10000,
                capTakenToday: state == .idle ? 0 : 3870)
            return MenuBarPanel.AgentsInput(isAllowed: true, activity: activity, budget: budget)
        }

        private static func job(
            _ name: String, _ mode: Mode, _ state: JobState, progress: Double = 0, minutesAgo: Double, now: Date
        ) -> Job {
            let spec = JobSpec(
                mode: mode,
                source: SourceClip(
                    fileURL: URL(filePath: "/tmp/\(name).mov"), duration: 12,
                    pixelSize: PixelSize(width: 1280, height: 720), range: 0...8),
                resolution: .p720)
            var job = Job(
                spec: spec, providerKind: .apiKey, cost: .usd(Decimal(125) / 100, isEstimate: false),
                createdAt: now.addingTimeInterval(-minutesAgo * 60))
            job.state = state
            job.progress = progress
            return job
        }

        private static func origin(hold: AgentHold?) -> AgentOrigin {
            AgentOrigin(
                client: "claude-code", requestID: UUID().uuidString, maxCost: AgentMoney(200, .usdCents), hold: hold)
        }
    }
#endif
