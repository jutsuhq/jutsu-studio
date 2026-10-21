import Foundation
import JutsuCore
import Testing

@testable import Presentation

/// What capabilities and quote say about variants before create_video refuses them.
@Suite struct AgentVariantsTests {
    func capabilities(maxVariants: Int, unlimited: [VideoModel: Set<Mode>] = [:]) -> Capabilities {
        Capabilities(
            modes: Set(Mode.allCases), models: Set(VideoModel.allCases), resolutions: [.p720], costUnit: .credits,
            maxConcurrency: nil, unlimited: unlimited, maxVariants: maxVariants)
    }

    @Test func eachReasonForOneVideoIsSaid() {
        let account = capabilities(maxVariants: 4, unlimited: [.seedance25: [.motionTransfer]])
        let open = AgentVideoOrder.variants(
            of: .seedance25, in: .motionTransfer, capabilities: account, unlimitedOptIn: false)
        #expect(open == AgentVideoOrder.Variants(maximum: 4))
        let unlimited = AgentVideoOrder.variants(
            of: .seedance25, in: .motionTransfer, capabilities: account, unlimitedOptIn: true)
        #expect(unlimited.maximum == 1)
        #expect(unlimited.reason?.contains("Use unlimited generations") == true)
        // The allowance covers another mode: variants stay.
        #expect(
            AgentVideoOrder.variants(of: .seedance25, in: .objectSwap, capabilities: account, unlimitedOptIn: true)
                .maximum == 4)
        let style = AgentVideoOrder.variants(of: .genjutsu, in: .restyle, capabilities: account, unlimitedOptIn: false)
        #expect(style.maximum == 1 && style.reason?.contains("style") == true)
        let apiKey = AgentVideoOrder.variants(
            of: .seedance25, in: .motionTransfer, capabilities: capabilities(maxVariants: 1), unlimitedOptIn: false)
        #expect(apiKey.maximum == 1 && apiKey.reason?.contains("one video per job") == true)
        let unknown = AgentVideoOrder.variants(
            of: .seedance25, in: .motionTransfer, capabilities: nil, unlimitedOptIn: false)
        #expect(unknown.maximum == 1 && unknown.reason != nil)
    }
}
