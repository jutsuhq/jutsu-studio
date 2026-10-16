import Foundation
import JutsuCore
import Testing

@testable import Presentation

/// The Create draft saved in the user's defaults names its model by ID, as before the catalog.
@Suite struct CreateFormModelCatalogTests {
    @Test(arguments: ["genjutsu", "seedance25", "klingMotionControl"])
    func aSavedDraftKeepsItsModel(id: String) throws {
        let form = CreateForm(mode: .motionTransfer, resolution: .p720)
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(form)) as? [String: Any])
        #expect(object["model"] as? String == "genjutsu")
        object["model"] = id
        let saved = try JSONDecoder().decode(CreateForm.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(saved.model.rawValue == id)
    }

    /// Each control shows on the models that declare it, as it did on the model it was written for.
    @Test func controlsFollowTheCatalog() {
        func form(_ model: VideoModel) -> CreateForm {
            var form = CreateForm(mode: .motionTransfer, resolution: .p720)
            form.model = model
            return form
        }
        let models: [VideoModel] = [.genjutsu, .seedance25, .klingMotionControl]
        #expect(models.map { form($0).showsBitrate } == [false, true, false])
        #expect(models.map { form($0).showsFrames } == [false, true, false])
        #expect(models.map { form($0).showsKlingQuality } == [false, false, true])
        #expect(models.map { form($0).showsVideoBackground } == [false, false, true])
        #expect(models.map { form($0).showsCharacterOrientation } == [false, false, true])
        #expect(models.map { form($0).offersDraft } == [true, true, false])
        #expect(models.map { form($0).isWithoutSource } == [false, true, false])
    }
}
