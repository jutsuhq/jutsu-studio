import Foundation
import JutsuCore
import Testing

@testable import Presentation

@Suite struct CreateFormCodingTests {
    /// Every field set, as the form wrote it while all its stored properties were its own.
    private static let flatDraft = #"""
        {"allowsUpscale":true,"aspectRatio":"9:16","audio":"fadeOut",\#
        "batchPresetIDs":["22222222-2222-2222-2222-222222222222"],\#
        "characterSets":[[{"fileURL":"file:\/\/\/tmp\/ref5.png"}]],"cinemaPicks":{"genre":"noir"},\#
        "draftLength":"firstFiveSeconds","draftResolution":"480p","endFrame":{"fileURL":"file:\/\/\/tmp\/ref4.png"},\#
        "isBatch":true,"keepsVideoBackground":true,"klingOrientation":"image","length":7,"mode":"motionTransfer",\#
        "model":"genjutsu","parentID":"33333333-3333-3333-3333-333333333333",\#
        "presetID":"11111111-1111-1111-1111-111111111111","prompt":"Image 1 dances","ranges":[[0,12]],\#
        "references":[{"fileURL":"file:\/\/\/tmp\/ref1.png"},{"fileURL":"file:\/\/\/tmp\/ref2.png"}],\#
        "remoteInputs":{"images":[],"video":{"id":"v1","url":"https:\/\/cdn.example\/clip.mp4"}},\#
        "resolution":"720p","savedCharacterSets":[["file:\/\/\/tmp\/ref5.png"],{"id":"el1","owner":"me"}],\#
        "seedanceBitrate":"standard","selectedRangeIndex":0,\#
        "source":{"codec":"avc1","duration":12,"fileSize":1,"fileURL":"https:\/\/cdn.example\/clip.mp4",\#
        "pixelSize":{"height":720,"width":1280}},"startFrame":{"fileURL":"file:\/\/\/tmp\/ref3.png"},"variantCount":3}
        """#

    @Test func aDraftSavedBeforeTheGroupsDecodesAndIsWrittenTheSame() throws {
        let form = try JSONDecoder().decode(CreateForm.self, from: Data(Self.flatDraft.utf8))

        #expect(form.bitrate(on: .account) == .standard)
        #expect(form.characterOrientation == .image)
        #expect(form.cinemaControls[.genre] == "noir")
        #expect(form.variants == 3)
        #expect(form.frame(.start)?.fileURL == CreateFixture.image(3))
        #expect(form.frame(.end)?.fileURL == CreateFixture.image(4))
        #expect(form.isBatch)
        #expect(form.characterSets == [CreateFixture.references([CreateFixture.image(5)])])
        #expect(form.savedElement(ofCharacterSet: 0, owner: "me") == SavedElement(id: "el1", owner: "me"))
        #expect(form.remoteInputs?.video?.id == "v1")

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(String(decoding: try encoder.encode(form), as: UTF8.self) == Self.flatDraft)
    }
}

@Suite struct FramePairTests {
    @Test func aJobsImagesFillTheSlotsInOrder() {
        let images = CreateFixture.references([CreateFixture.image(1), CreateFixture.image(2), CreateFixture.image(3)])
        var frames = FramePair(images)
        #expect(frames[.start] == images[0] && frames[.end] == images[1])
        #expect(frames.images == Array(images.prefix(2)))
        frames[.start] = nil
        #expect(frames.images == [images[1]])
        #expect(!frames.isEmpty)
        frames[.end] = nil
        #expect(frames.isEmpty && FramePair().isEmpty)
    }
}

@Suite struct CreateBatchTests {
    private let images = CreateFixture.references([CreateFixture.image(1), CreateFixture.image(2)])

    @Test func aFullListTakesNoNewStyleButLetsOneGo() {
        var batch = CreateBatch()
        let (first, second) = (UUID(), UUID())
        let added = [batch.togglePreset(first, limit: 1), batch.togglePreset(second, limit: 1)]
        #expect(added == [true, false])
        #expect(batch.presetIDs == [first])
        let removed = batch.togglePreset(first, limit: 1)
        #expect(removed && batch.presetIDs.isEmpty)
        #expect(batch.count(in: .restyle) == 0)
    }

    @Test func aPublishedSetStaysPublishedWhileAnEqualSetIsLeft() {
        var batch = CreateBatch(characterSets: [images, images])
        let element = SavedElement(id: "el", owner: "me")
        batch.setSavedElement(element, forCharacterSet: images)
        #expect(batch.savedElement(ofCharacterSet: 1, owner: "me") == element)
        #expect(batch.savedElement(ofCharacterSet: 1, owner: "someone else") == nil)
        batch.removeCharacterSet(at: 0)
        #expect(batch.savedElement(ofCharacterSet: 0, owner: "me") == element)
        batch.removeCharacterSet(at: 0)
        #expect(batch.savedSets?.isEmpty == true)
        #expect(batch.count(in: .motionTransfer) == 0)
    }

    @Test func reopeningKeepsThePublishedMarkOnlyForWholeSets() {
        var batch = CreateBatch(characterSets: [images, [images[0]]])
        let element = SavedElement(id: "el", owner: nil)
        batch.setSavedElement(element, forCharacterSet: images)
        batch.setSavedElement(element, forCharacterSet: [images[0]])
        let moved = LocalImage(fileURL: URL(fileURLWithPath: "/tmp/moved.png"))

        let reopened = batch.reopeningSets { $0 == images[0] ? moved : nil }

        // The first set lost a file, so only the second is still the one published.
        #expect(reopened.characterSets == [[moved], [moved]])
        #expect(reopened.savedSets == [[moved.fileURL]: element])
        #expect(CreateBatch(characterSets: [images]).reopeningSets { _ in nil }.characterSets.isEmpty)
    }
}
