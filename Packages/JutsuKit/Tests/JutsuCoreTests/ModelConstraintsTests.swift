import Foundation
import Testing

@testable import JutsuCore

@Suite struct ModelConstraintsTests {
    static func table(
        _ model: VideoModel, _ constraints: ModelConstraints, mode: Mode = .motionTransfer
    )
        -> ModelConstraintTable
    {
        ModelConstraintTable(entries: [.init(model: model, mode: mode, constraints: constraints)])
    }

    @Test func theTableReplacesTheConstantsItStates() {
        let table = Self.table(.seedance25, ModelConstraints(maxDuration: 45, maxReferenceImages: 4))
        let limits = VideoModel.seedance25.limits(for: .motionTransfer, constraints: table)
        #expect(limits.duration == 4...45)
        #expect(limits.referenceImages == 1...4)
    }

    @Test func aMissingBoundKeepsItsConstant() {
        let table = Self.table(.klingMotionControl, ModelConstraints(maxReferenceImages: 2))
        let limits = VideoModel.klingMotionControl.limits(for: .motionTransfer, constraints: table)
        #expect(limits.referenceImages == 1...2)
        #expect(limits.duration == VideoModel.klingMotionControl.limits(for: .motionTransfer).duration)
    }

    @Test func boundsThatContradictEachOtherKeepTheConstants() {
        let table = Self.table(.seedance25, ModelConstraints(minDuration: 40, minReferenceImages: 9))
        #expect(
            VideoModel.seedance25.limits(for: .motionTransfer, constraints: table)
                == .init(
                    referenceImages: 1...8, requiresPreset: false, duration: 4...30))
    }

    @Test func anEntryAppliesOnlyToItsModelAndMode() {
        let table = Self.table(.genjutsu, ModelConstraints(maxReferenceImages: 3), mode: .objectSwap)
        #expect(VideoModel.genjutsu.limits(for: .objectSwap, constraints: table).referenceImages == 1...3)
        #expect(VideoModel.genjutsu.limits(for: .motionTransfer, constraints: table).referenceImages == 1...8)
        #expect(VideoModel.seedance25.limits(for: .objectSwap, constraints: table).referenceImages == 1...8)
    }

    @Test func withoutASourceNoImageIsRequiredWhateverTheTableSays() {
        let table = Self.table(.seedance25, ModelConstraints(minReferenceImages: 2, maxReferenceImages: 5))
        #expect(
            VideoModel.seedance25.limits(for: .motionTransfer, hasSource: false, constraints: table).referenceImages
                == 0...5)
    }

    @Test func validationChecksAgainstTheTable() {
        let source = SourceClip(
            fileURL: URL(fileURLWithPath: "/tmp/in.mp4"), duration: 60, pixelSize: PixelSize(width: 1280, height: 720),
            range: 0...40)
        let spec = JobSpec(
            mode: .motionTransfer, model: .seedance25, source: source,
            references: [
                LocalImage(
                    fileURL: URL(
                        fileURLWithPath: "/tmp/a.png"))
            ], prompt: "", resolution: .p720)
        #expect(Validation.check(spec) == [.durationTooLong(40)])
        #expect(Validation.check(spec, constraints: Self.table(.seedance25, ModelConstraints(maxDuration: 45))).isEmpty)
    }

    @Test func invalidValuesAreDropped() {
        let constraints = ModelConstraints(
            minDuration: -1, maxDuration: .infinity, minReferenceImages: -2, maxReferenceImages: 3)
        #expect(constraints == ModelConstraints(maxReferenceImages: 3))
    }

    @Test func junkDecodesToWhatCanBeRead() throws {
        let json = """
            {"entries": [
              {"model": "seedance25", "mode": "motionTransfer",
               "constraints": {"maxDuration": "45", "minDuration": 5, "maxReferenceImages": 2.5, "extra": true}},
              {"model": "veo", "mode": "motionTransfer", "constraints": {"maxDuration": 8}},
              {"model": "genjutsu", "mode": "dance", "constraints": {}},
              {"model": "klingMotionControl", "mode": "motionTransfer"},
              "nonsense", 12, null
            ]}
            """
        let table = try JSONDecoder().decode(ModelConstraintTable.self, from: Data(json.utf8))
        #expect(table.entries.count == 1)
        #expect(table[.seedance25, .motionTransfer] == ModelConstraints(minDuration: 5))
    }

    @Test func aTableWithoutEntriesIsTheConstants() throws {
        #expect(try JSONDecoder().decode(ModelConstraintTable.self, from: Data("{}".utf8)) == .builtIn)
    }

    @Test func differencesFromTheConstantsAreListed() {
        #expect(Self.table(.seedance25, ModelConstraints(maxDuration: 30)).differencesFromBuiltIn.isEmpty)
        let differences = Self.table(.seedance25, ModelConstraints(maxDuration: 15)).differencesFromBuiltIn
        #expect(differences.count == 1)
        #expect(differences.first?.contains("seedance25 motionTransfer") == true)
    }
}
