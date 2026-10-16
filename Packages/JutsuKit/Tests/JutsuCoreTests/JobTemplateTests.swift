import Foundation
import Testing

@testable import JutsuCore

@Suite struct JobTemplateTests {
    @Test func takesTheSpecInputsButNotTheSource() {
        var spec = makeSpec(mode: .restyle, references: 2, presetID: UUID(), prompt: "rain", resolution: .p1080)
        spec.audio = .mute
        let template = JobTemplate(name: "Rain", spec: spec)
        #expect(template.mode == .restyle)
        #expect(template.references == spec.references)
        #expect(template.presetID == spec.presetID)
        #expect(template.prompt == "rain")
        #expect(template.resolution == .p1080)
        #expect(template.audio == .mute)
    }

    @Test func dropsThePresetOutsideRestyle() {
        let template = JobTemplate(name: "Swap", mode: .objectSwap, presetID: UUID(), resolution: .p720)
        #expect(template.presetID == nil)
    }

    @Test func roundTripsThroughJSON() throws {
        let template = JobTemplate(
            name: "Neon", createdAt: Date(timeIntervalSince1970: 1_000), mode: .restyle,
            references: [LocalImage(fileURL: URL(fileURLWithPath: "/tmp/a.png"))], presetID: UUID(),
            prompt: "neon", resolution: .p720, audio: .fadeOut)
        let decoded = try JSONDecoder().decode(JobTemplate.self, from: JSONEncoder().encode(template))
        #expect(decoded == template)

        let kling = JobTemplate(name: "Dance", mode: .motionTransfer, model: .klingMotionControl, resolution: .p1080)
        #expect(
            try JSONDecoder().decode(JobTemplate.self, from: JSONEncoder().encode(kling)).model == .klingMotionControl)
    }

    @Test func keepsTheSpecModel() {
        var spec = makeSpec(mode: .motionTransfer)
        spec.model = .seedance25
        #expect(JobTemplate(name: "Dance", spec: spec).model == .seedance25)
    }

    @Test func aModelThatDoesntServeTheModeIsGenjutsu() {
        let template = JobTemplate(name: "Swap", mode: .objectSwap, model: .seedance25, resolution: .p720)
        #expect(template.model == .genjutsu)
    }

    @Test func storedBeforeModelsDecodesAsGenjutsu() throws {
        let current = JobTemplate(name: "Old", mode: .motionTransfer, model: .seedance25, resolution: .p720)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(current))
        var object = try #require(encoded as? [String: Any])
        #expect(object.removeValue(forKey: "model") != nil)
        let old = try JSONSerialization.data(withJSONObject: object)

        let template = try JSONDecoder().decode(JobTemplate.self, from: old)
        #expect(template.model == .genjutsu)
        #expect(template.name == "Old")
        #expect(template.resolution == .p720)
    }

    @Test func storedBeforeTheModelParametersDecodesWithout() throws {
        let current = JobTemplate(
            name: "Old", mode: .motionTransfer, model: .seedance25, resolution: .p720, bitrate: .standard,
            characterOrientation: .image, referencesAreFrames: true)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(current))
        var object = try #require(encoded as? [String: Any])
        for key in ["bitrate", "characterOrientation", "referencesAreFrames"] {
            #expect(object.removeValue(forKey: key) != nil)
        }
        let old = try JSONSerialization.data(withJSONObject: object)

        let template = try JSONDecoder().decode(JobTemplate.self, from: old)
        #expect(template.bitrate == nil && template.characterOrientation == nil && !template.referencesAreFrames)
        #expect(try JSONDecoder().decode(JobTemplate.self, from: JSONEncoder().encode(current)) == current)
    }

    @Test func imageTemplateRoundTripsThroughJSON() throws {
        let template = JobTemplate(
            name: "Knight", createdAt: Date(timeIntervalSince1970: 2_000), imageModelID: "soul",
            imageModelTitle: "Soul 2", imageAspectRatio: "16:9", imageCount: 4, prompt: "a knight",
            references: [LocalImage(fileURL: URL(fileURLWithPath: "/tmp/knight.png"))])
        #expect(template.kind == .image)

        let decoded = try JSONDecoder().decode(JobTemplate.self, from: JSONEncoder().encode(template))
        #expect(decoded == template)
    }

    @Test func storedBeforeKindsDecodesAsVideo() throws {
        let current = JobTemplate(
            name: "Old", mode: .motionTransfer, model: .seedance25, resolution: .p720, imageModelID: "soul",
            imageModelTitle: "Soul", imageAspectRatio: "16:9", imageCount: 4)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(current))
        var object = try #require(encoded as? [String: Any])
        for key in ["kind", "imageModelID", "imageModelTitle", "imageAspectRatio", "imageCount"] {
            #expect(object.removeValue(forKey: key) != nil)
        }
        let old = try JSONSerialization.data(withJSONObject: object)

        let template = try JSONDecoder().decode(JobTemplate.self, from: old)
        #expect(template.kind == .video)
        #expect(template.imageModelID == nil && template.imageAspectRatio == nil && template.imageCount == 1)
        #expect(template.name == "Old")
    }
}

@Suite struct TemplateFilesTests {
    @Test func fileNamesKeepOrderAndSameNamesApart() {
        let sources = [
            URL(fileURLWithPath: "/a/face.png"), URL(fileURLWithPath: "/b/face.png"),
            URL(fileURLWithPath: "/c/shirt.jpg"),
        ]
        #expect(TemplateFiles.fileNames(for: sources) == ["1-face.png", "2-face.png", "3-shirt.jpg"])
        #expect(TemplateFiles.fileNames(for: []) == [])
    }

    @Test func orphansAreFoldersWithoutATemplate() {
        let kept = UUID()
        let gone = UUID()
        let folders = [kept.uuidString, gone.uuidString, "notes"]
        #expect(
            TemplateFiles.orphanedFolders(folders, keeping: [kept]) == [gone.uuidString, "notes"].sorted())
        #expect(TemplateFiles.orphanedFolders([kept.uuidString], keeping: [kept]).isEmpty)
    }
}
