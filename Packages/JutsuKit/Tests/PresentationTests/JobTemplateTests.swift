import Foundation
import JutsuCore
import Testing

@testable import Presentation

@Suite struct CreateFormTemplateTests {
    @Test func templateKeepsTheInputsWithoutTheSource() {
        var form = CreateFixture.ready(.p1080)
        form.mode = .restyle
        form.presetID = UUID()
        form.prompt = "rainy neon"
        form.audio = .fadeOut
        let template = form.makeTemplate(name: "Neon")
        #expect(template.name == "Neon")
        #expect(template.mode == .restyle)
        #expect(template.references == form.references)
        #expect(template.presetID == form.presetID)
        #expect(template.prompt == "rainy neon")
        #expect(template.resolution == .p1080)
        #expect(template.audio == .fadeOut)
    }

    @Test func applyFillsTheInputsAndKeepsSourceAndRanges() {
        var form = CreateForm()
        form.setSource(CreateFixture.video(duration: 40))
        form.addRange()
        form.setEnd(20)
        let ranges = form.ranges
        let source = form.source
        let preset = UUID()
        let template = JobTemplate(
            name: "Clay", mode: .restyle, references: CreateFixture.references([CreateFixture.image(1)]),
            presetID: preset, prompt: "clay", resolution: .p720, audio: .mute)

        form.apply(template)

        #expect(form.source == source)
        #expect(form.ranges == ranges)
        #expect(form.mode == .restyle)
        #expect(form.references == template.references)
        #expect(form.presetID == preset)
        #expect(form.prompt == "clay")
        #expect(form.resolution == .p720)
        #expect(form.audio == .mute)
    }

    @Test func applyWithoutASourceLeavesOnlyTheVideoToAdd() {
        var form = CreateForm()
        form.apply(
            JobTemplate(
                name: "Dance", mode: .motionTransfer,
                references: CreateFixture.references([CreateFixture.image(1)]), resolution: .p720))
        #expect(form.source == nil)
        #expect(form.blocker(isDraft: false, in: CreateFixture.apiKey) == "Add a source video")
    }

    @Test func applyReplacesReferencesAndKeepsAPresetANonRestyleTemplateHasNone() {
        var form = CreateFixture.ready()
        form.addReferences(CreateFixture.references([CreateFixture.image(2)]))
        let preset = UUID()
        form.presetID = preset
        form.apply(
            JobTemplate(
                name: "Swap", mode: .objectSwap,
                references: CreateFixture.references([CreateFixture.image(7)]), resolution: .p480))
        #expect(form.references == CreateFixture.references([CreateFixture.image(7)]))
        #expect(form.presetID == preset)
    }

    @Test func applyCutsReferencesToTheModeLimit() {
        var form = CreateForm()
        let images = CreateFixture.references((1...7).map(CreateFixture.image))
        form.apply(JobTemplate(name: "Many", mode: .restyle, references: images, resolution: .p720))
        #expect(form.references.count == 5)
    }

    @Test func templateKeepsTheSelectedModel() {
        var form = CreateFixture.ready()
        form.model = .klingMotionControl
        #expect(form.makeTemplate(name: "Dance").model == .klingMotionControl)
        form.mode = .objectSwap
        #expect(form.makeTemplate(name: "Swap").model == .genjutsu)
    }

    @Test func applyUsesTheTemplateModelWhenTheConnectionOffersIt() {
        var form = CreateFixture.ready()
        let template = JobTemplate(name: "Dance", mode: .motionTransfer, model: .seedance25, resolution: .p720)
        let message = form.apply(template, offered: Set(VideoModel.allCases))
        #expect(message == nil)
        #expect(form.selectedModel == .seedance25)
        #expect(form.makeSpecs(isDraft: false).map(\.model) == [.seedance25])
    }

    @Test func applyFallsBackToGenjutsuWithANotice() {
        var form = CreateFixture.ready()
        form.model = .seedance25
        let template = JobTemplate(
            name: "Dance", mode: .motionTransfer, model: .klingMotionControl,
            references: CreateFixture.references([CreateFixture.image(3)]), prompt: "spin", resolution: .p1080)

        let message = form.apply(template)

        #expect(form.model == .genjutsu)
        #expect(message?.title == "Running on Genjutsu")
        #expect(message?.message == "\"Dance\" uses Kling 3.0, which this connection doesn't offer.")
        #expect(form.prompt == "spin")
        #expect(form.references == template.references)
        #expect(form.resolution == .p1080)
    }

    @Test func summaryNamesAModelOtherThanGenjutsu() {
        let seedance = JobTemplate(name: "A", mode: .motionTransfer, model: .seedance25, resolution: .p720)
        #expect(seedance.summary == "\(Mode.motionTransfer.shortTitle) · Seedance 2.5 · 720p")
        let genjutsu = JobTemplate(name: "B", mode: .motionTransfer, resolution: .p720)
        #expect(genjutsu.summary == "\(Mode.motionTransfer.shortTitle) · 720p")
    }

    @Test func draftsSaveTheFinalResolution() {
        let draft = LibraryFixture.item(resolution: .p480, isDraft: true)
        #expect(draft.templateSpec(finalResolution: .p720).resolution == .p720)
        let final = LibraryFixture.item(resolution: .p1080, isDraft: false)
        #expect(final.templateSpec(finalResolution: .p720).resolution == .p1080)
    }
}

@Suite struct TemplateNamingTests {
    @Test func suggestedNameUsesModeAndFirstPromptLine() {
        let name = TemplateNaming.suggestedName(mode: .restyle, prompt: "  rainy neon\nsecond line")
        #expect(name == "Restyle · rainy neon")
        #expect(TemplateNaming.suggestedName(mode: .objectSwap, prompt: "") == "Swap")
    }

    @Test func longNamesAreCut() {
        let name = TemplateNaming.suggestedName(mode: .motionTransfer, prompt: String(repeating: "a", count: 200))
        #expect(name.count == TemplateNaming.maximumLength)
        #expect(name.hasSuffix("…"))
    }

    @Test func uniqueNameNumbersTakenNames() {
        #expect(TemplateNaming.uniqueName("Neon", among: []) == "Neon")
        #expect(TemplateNaming.uniqueName(" Neon ", among: ["neon"]) == "Neon 2")
        #expect(TemplateNaming.uniqueName("Neon", among: ["Neon", "Neon 2"]) == "Neon 3")
    }

    @Test func emptyNameFallsBack() {
        #expect(TemplateNaming.uniqueName("  ", among: []) == "Untitled template")
        #expect(TemplateNaming.uniqueName("", among: ["Untitled template"]) == "Untitled template 2")
    }

    @Test func summaryListsTheInputs() {
        let images = CreateFixture.references([CreateFixture.image(1), CreateFixture.image(2)])
        let template = JobTemplate(
            name: "A", mode: .motionTransfer, references: images, resolution: .p720, audio: .mute)
        #expect(template.summary == "Motion · 2 images · 720p · Mute")
        #expect(JobTemplate(name: "B", mode: .restyle, resolution: .p480).summary == "Restyle · 480p")
    }
}
