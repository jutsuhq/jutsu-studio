import Foundation
import JutsuCore
import Testing

@testable import Presentation

@Suite struct MakeVideoTests {
    static let version = MaterialReference(materialID: UUID(), versionID: UUID())
    static let start = LocalImage(fileURL: URL(fileURLWithPath: "/tmp/start.png"), material: version)
    static let end = LocalImage(fileURL: URL(fileURLWithPath: "/tmp/end.png"))
    static let third = LocalImage(fileURL: URL(fileURLWithPath: "/tmp/third.png"))

    static func seedance() -> CreateForm {
        var form = CreateForm(mode: .motionTransfer, resolution: .p720)
        form.model = .seedance25
        return form
    }

    // MARK: Role options

    @Test func rolesFollowTheModelsDeclaredInputs() {
        #expect(ImageRole.options(for: .seedance25, mode: .motionTransfer) == [.startFrame, .endFrame, .reference])
        #expect(ImageRole.options(for: .genjutsu, mode: .restyle) == [.reference])
        #expect(ImageRole.options(for: .klingMotionControl, mode: .motionTransfer) == [.reference])
        // Every model in models.json: frames only where it declares them, a reference where its limit takes one.
        for model in VideoModel.allCases {
            let mode = model.modes[0]
            let roles = ImageRole.options(for: model, mode: mode)
            #expect(roles.contains(.startFrame) == model.declares(.frames), "\(model.rawValue)")
            #expect(roles.contains(.reference) == (model.limits(for: mode).referenceImages.upperBound > 0))
        }
    }

    @Test func aReferenceAlreadyAddedIsPinnedToTheVersionItComesWith() {
        var form = CreateForm(mode: .restyle)
        form.model = .genjutsu
        _ = form.addReferences([LocalImage(fileURL: Self.start.fileURL)])
        #expect(form.makeVideo(from: [Self.start], as: MakeVideoChoice(roles: [.reference])) == nil)
        #expect(form.references.count == 1)
        #expect(form.references.first?.material == Self.version)
    }

    @Test func choicesAskOnlyWhenMoreThanOneFits() {
        let form = Self.seedance()
        #expect(form.makeVideoChoices(imageCount: 1).map(\.roles) == [[.startFrame], [.endFrame], [.reference]])
        #expect(
            form.makeVideoChoices(imageCount: 2).map(\.roles) == [[.startFrame, .endFrame], [.reference, .reference]])
        #expect(form.makeVideoChoices(imageCount: 3).map(\.roles) == [[.reference, .reference, .reference]])
        // The connection can't send frames, so they aren't offered.
        #expect(form.makeVideoChoices(imageCount: 1, takesFrames: false).map(\.roles) == [[.reference]])
        #expect(
            CreateForm(mode: .motionTransfer).makeVideoChoices(imageCount: 2).map(\.roles) == [
                [.reference, .reference]
            ])
        #expect(form.makeVideoChoices(imageCount: 0).isEmpty)
        #expect(MakeVideoChoice(roles: [.startFrame, .endFrame]).title == "Start and end frames")
        #expect(MakeVideoChoice(roles: [.endFrame]).title == "End frame")
    }

    // MARK: Placing

    @Test func framesReplaceTheSourceAndPinTheVersion() throws {
        var form = Self.seedance()
        form.mode = .edit
        form.setSource(CreateFixture.video())
        form.addReferences([Self.third])
        #expect(
            form.makeVideo(from: [Self.start, Self.end], as: MakeVideoChoice(roles: [.startFrame, .endFrame])) == nil)
        #expect(form.mode == .motionTransfer)
        #expect(form.source == nil)
        #expect(form.frame(.start) == Self.start)
        #expect(form.frame(.end) == Self.end)
        let spec = try #require(form.makeSpecs(isDraft: false).first)
        #expect(spec.usesFrames)
        #expect(spec.references.map(\.material) == [Self.version, nil])
        #expect(form.placedImages.map(\.role) == [.startFrame, .endFrame])
    }

    @Test func oneImageFillsTheRoleAsked() {
        var form = Self.seedance()
        _ = form.makeVideo(from: [Self.end], as: MakeVideoChoice(roles: [.endFrame]))
        #expect(form.frame(.end) == Self.end)
        #expect(form.frame(.start) == nil)
        #expect(form.references.isEmpty)
    }

    @Test func referencesStopTheFramesThatWouldLeaveThemUnused() {
        var form = Self.seedance()
        form.setFrame(Self.start, for: .start)
        _ = form.makeVideo(from: [Self.third], as: MakeVideoChoice(roles: [.reference]))
        #expect(!form.usesFrames)
        #expect(form.references == [Self.third])
        #expect(form.placedImages.map(\.role) == [.reference])
    }

    @Test func referencesOverTheLimitAreSaid() {
        var form = CreateFixture.ready()
        form.model = .klingMotionControl
        let message = form.makeVideo(
            from: [Self.start, Self.end], as: MakeVideoChoice(roles: [.reference, .reference]))
        #expect(message?.title == "2 images weren't added")
    }

    // MARK: Switching the model

    @Test func aModelWithoutFramesTurnsThemIntoReferences() throws {
        var form = Self.seedance()
        _ = form.makeVideo(from: [Self.start, Self.end], as: MakeVideoChoice(roles: [.startFrame, .endFrame]))
        let note = try #require(form.recheckingRoles { $0.model = .genjutsu })
        #expect(note == "Genjutsu doesn't take start and end frames, so they are references now.")
        #expect(form.references == [Self.start, Self.end])
        #expect(form.placedImages.map(\.role) == [.reference, .reference])
        #expect(form.references.first?.material == Self.version)
    }

    @Test func aSmallerLimitSaysWhatWasRemoved() throws {
        var form = Self.seedance()
        _ = form.makeVideo(from: [Self.start, Self.end], as: MakeVideoChoice(roles: [.startFrame, .endFrame]))
        let note = try #require(form.recheckingRoles { $0.model = .klingMotionControl })
        let kling = VideoModel.klingMotionControl.title
        #expect(note.hasPrefix("\(kling) doesn't take start and end frames"))
        #expect(note.hasSuffix("\(kling) takes up to 1 reference image: 1 image was removed."))
        // The start frame goes first, so the frame the clip started on is the one kept.
        #expect(form.references == [Self.start])
    }

    @Test func aSwitchThatKeepsEveryRoleSaysNothing() {
        var form = CreateFixture.ready()
        #expect(form.recheckingRoles { $0.model = .seedance25 } == nil)
        var frames = Self.seedance()
        frames.setFrame(Self.start, for: .start)
        #expect(frames.recheckingRoles { $0.length = 8 } == nil)
        #expect(frames.frame(.start) == Self.start)
    }

    @Test func aTabThatFallsBackToGenjutsuIsCheckedToo() {
        var form = Self.seedance()
        form.setFrame(Self.start, for: .start)
        let note = form.recheckingRoles { $0.tab = .restyle }
        #expect(note?.contains("Genjutsu") == true)
        #expect(form.references == [Self.start])
    }
}
