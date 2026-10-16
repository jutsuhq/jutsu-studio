import Foundation
import JutsuCore
import Testing

@testable import Presentation

/// Cinema Studio's creative controls in Create: shown only for it, carried by its jobs, its templates and a reopened
/// job, and said to be API key only on the account.
@Suite struct CinemaControlsFormTests {
    static let cinema = VideoModel(rawValue: "cinemaStudio4")

    static func cinemaForm() throws -> CreateForm {
        var form = CreateFixture.ready()
        form.model = try #require(Self.cinema)
        form.prompt = "a slow reveal"
        return form
    }

    @Test func onlyCinemaStudioShowsThemAndItsJobsCarryThem() throws {
        var form = CreateFixture.ready()
        #expect(!form.showsCinemaControls)

        form = try Self.cinemaForm()
        #expect(form.showsCinemaControls)
        #expect(form.cinemaControlsSummary == nil)
        #expect(try #require(form.makeSpecs(isDraft: false).first).cinemaControls.isEmpty)

        form[cinema: .cameraModel] = "35mm-film"
        form[cinema: .genre] = "noir"
        // Not one of the era's values: left to the director.
        form[cinema: .era] = "1970s"
        #expect(form.cinemaControlsSummary == "2 set")
        let spec = try #require(form.makeSpecs(isDraft: false).first)
        #expect(spec.cinemaControls.fields == ["camera_model": "35mm-film", "genre": "noir"])

        // Another model sends none, and the picks wait for Cinema Studio.
        form.model = .genjutsu
        #expect(try #require(form.makeSpecs(isDraft: false).first).cinemaControls.isEmpty)
        form.model = try #require(Self.cinema)
        #expect(form[cinema: .genre] == "noir")

        form[cinema: .cameraModel] = nil
        form[cinema: .genre] = nil
        #expect(form.cinemaControlsSummary == nil)
    }

    @Test func aReopenedJobAndATemplateKeepThem() throws {
        var form = try Self.cinemaForm()
        form[cinema: .cameraMovement] = "dolly-in"
        form[cinema: .colorPalette] = "neon-rain-at-midnight"
        let spec = try #require(form.makeSpecs(isDraft: false).first)

        var reopened = CreateForm()
        reopened.load(spec, source: CreateFixture.video())
        #expect(reopened.cinemaControls == spec.cinemaControls)

        let template = form.makeTemplate(name: "Night")
        #expect(template.cinemaControls == spec.cinemaControls)
        var applied = CreateForm()
        applied.apply(template, offered: Set(VideoModel.allCases))
        #expect(applied.cinemaControls == spec.cinemaControls)

        // A Cinema Studio job without picks clears the form's.
        form[cinema: .cameraMovement] = nil
        form[cinema: .colorPalette] = nil
        reopened.load(try #require(form.makeSpecs(isDraft: false).first), source: CreateFixture.video())
        #expect(reopened.cinemaControls.isEmpty)
    }

    @Test func aDraftSavedBeforeThemStillDecodes() throws {
        var form = try Self.cinemaForm()
        form[cinema: .pacing] = "calm"
        #expect(try JSONDecoder().decode(CreateForm.self, from: JSONEncoder().encode(form)) == form)

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(form))
        var object = try #require(encoded as? [String: Any])
        #expect(object.removeValue(forKey: "cinemaPicks") != nil)
        let old = try JSONDecoder().decode(CreateForm.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.cinemaControls.isEmpty)
    }

    /// The account takes the controls as IDs its catalog doesn't list, so Create disables them there.
    @Test func theAccountSaysTheyAreAPIKeyOnly() {
        #expect(
            CreateFormModelOptionsTests.account.unavailableReason(for: .cinemaControls)
                == "Cinema Studio's creative controls are set only with an API key, not on the account")
        #expect(CreateFormModelOptionsTests.apiKey.unavailableReason(for: .cinemaControls) == nil)
    }
}
