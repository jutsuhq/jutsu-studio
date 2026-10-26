import Foundation
import JutsuAgent
import JutsuCore
import Testing

@testable import Presentation

/// The translations between the app's values and the agents' wire types (`AgentWire+Domain.swift`).
@Suite struct AgentWireDomainTests {
    /// The helper can't link JutsuCore, so the bound is named on both sides; agents are told the one the app sends by.
    @Test func theInputBoundIsTheSameOnBothSides() {
        #expect(ImageModel.inputBound == AgentImageRequest.maxInputs)
        let open = ImageModel(
            id: "open", title: "Open", aspectRatios: ["1:1"], input: .optional,
            unstatedInputLimit: ImageModel.inputBound)
        let wire = AgentCapabilities.ImageModel(open)
        #expect(wire.maxInputs == AgentImageRequest.maxInputs)
        #expect(wire.maxInputsNote == AgentCapabilities.ImageModel.boundNote)
    }
}
