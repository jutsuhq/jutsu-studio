import Foundation
import Testing

@testable import JutsuCore

/// Cinema Studio 4.0's creative controls: only the schema's values, coded as the body's fields, kept by jobs and
/// templates, and titled from `Models.xcstrings`.
@Suite struct CinemaControlsTests {
    /// Whether this build compiled `Models.xcstrings`: SwiftPM on Linux and before Xcode 27 copies it as it is, which
    /// leaves the stand-in titles; Xcode builds of the app always compile it.
    static let compilesStringCatalogs =
        JutsuCoreResources.bundle.url(
            forResource: "Models", withExtension: "strings", subdirectory: nil, localization: "en") != nil

    static let cinema = VideoModel(rawValue: "cinemaStudio4")

    @Test func onlyTheSchemasValuesAreKept() {
        var controls = CinemaControls([.genre: "noir", .era: "1970s"])
        #expect(controls.fields == ["genre": "noir"])
        controls[.genre] = "western"
        #expect(controls.isEmpty)
        controls[.light] = "contre-jour"
        #expect(controls[.light] == "contre-jour" && controls.count == 1)
    }

    /// Stored as the body's fields; a field or value another version wrote and this one doesn't know is dropped.
    @Test func itCodesAsTheBodysFields() throws {
        let controls = CinemaControls([.cameraLens: "anamorphic", .colorPalette: "yellow-room"])
        let data = try JSONEncoder().encode(controls)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: String]
        #expect(object == ["camera_lens": "anamorphic", "color_palette": "yellow-room"])
        #expect(try JSONDecoder().decode(CinemaControls.self, from: data) == controls)

        let newer = Data(#"{"camera_lens": "fisheye", "genre": "epic", "weather": "rain"}"#.utf8)
        #expect(try JSONDecoder().decode(CinemaControls.self, from: newer) == CinemaControls([.genre: "epic"]))
    }

    @Test func jobsAndTemplatesKeepThemAndOlderOnesHaveNone() throws {
        let controls = CinemaControls([.cameraModel: "8mm-film", .pacing: "single-shot"])
        let spec = JobSpec(
            mode: .motionTransfer, model: try #require(Self.cinema), source: nil, prompt: "rain", resolution: .p720,
            cinemaControls: controls)
        let decoded = try JSONDecoder().decode(JobSpec.self, from: JSONEncoder().encode(spec))
        #expect(decoded.cinemaControls == controls && decoded == spec)
        #expect(JobTemplate(name: "Night", spec: spec).cinemaControls == controls)

        let template = JobTemplate(name: "Night", spec: spec)
        let decodedTemplate = try JSONDecoder().decode(JobTemplate.self, from: JSONEncoder().encode(template))
        #expect(decodedTemplate == template)

        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(spec)) as? [String: Any])
        #expect(object.removeValue(forKey: "cinemaControls") != nil)
        let old = try JSONDecoder().decode(JobSpec.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.cinemaControls.isEmpty)
    }

    /// Every control and value has its English title in `Models.xcstrings`, not the stand-in made from the value.
    @Test(.enabled(if: Self.compilesStringCatalogs)) func everyTitleIsInTheStringCatalog() {
        let missing = "\u{1}missing"
        for control in CinemaControl.allCases {
            let field = "cinemaStudio4.\(control.rawValue)"
            let keys = [field] + control.options.map { "\(field).\($0)" }
            for key in keys {
                let title = JutsuCoreResources.bundle.localizedString(forKey: key, value: missing, table: "Models")
                #expect(title != missing, "\(key)")
            }
        }
        #expect(CinemaControl.cameraAperture.title(of: "f14-wide-open") == "f/1.4, wide open")
        #expect(
            CinemaControl.colorPalette.title(of: "dont-turn-it-off-im-watching") == "Don't Turn It Off, I'm Watching")
        #expect(CinemaControl.light.title == "Lighting")
        #expect(CinemaControl.genre.title(of: "space-opera") == "Space opera")
    }

    @Test func onlyCinemaStudioDeclaresThem() {
        #expect(VideoModel.allCases.filter { $0.declares(.cinemaControls) }.map(\.rawValue) == ["cinemaStudio4"])
    }
}
