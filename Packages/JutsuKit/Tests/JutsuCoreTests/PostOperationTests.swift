import Foundation
import Testing

@testable import JutsuCore

@Suite struct PostOperationTests {
    static let spec = JobSpec(
        mode: .motionTransfer,
        source: SourceClip(
            fileURL: URL(fileURLWithPath: "/tmp/out.mp4"), duration: 5, pixelSize: PixelSize(width: 640, height: 360),
            range: 0...5), resolution: .p720)

    @Test func anOperationSurvivesASaveAndRelaunch() throws {
        var spec = Self.spec
        spec.operation = PostOperation(
            action: .upscale(UpscaleOptions(target: .k4, frameRate: .fps30, engine: .topaz)), sourceJobID: "job-1")
        let job = Job(spec: spec, providerKind: .account, parentID: UUID(), cost: .unknownCredits)

        let decoded = try JSONDecoder().decode(Job.self, from: JSONEncoder().encode(job))

        #expect(decoded == job)
        #expect(decoded.priceIsUnknown)
    }

    /// Jobs, templates' specs and drafts stored before operations existed have no `operation` key.
    @Test func aSpecWithoutOperationDecodesAsAGeneration() throws {
        let data = try JSONEncoder().encode(Self.spec)
        #expect(String(decoding: data, as: UTF8.self).contains("operation") == false)
        #expect(try JSONDecoder().decode(JobSpec.self, from: data).operation == nil)
    }

    /// Operations as jobs stored them before Reframe, Dub and Change Voice existed, written out as literal JSON so a
    /// change to the coding shows here rather than in a user's library.
    @Test func operationsStoredBeforeTheNewCasesStillDecode() throws {
        let upscale = Data(
            #"{"action":{"upscale":{"_0":{"target":"4k","frameRate":0,"engine":"topaz"}}},"sourceJobID":"job-1"}"#.utf8)
        let cutout = Data(#"{"action":{"removeBackground":{}}}"#.utf8)

        #expect(
            try JSONDecoder().decode(PostOperation.self, from: upscale)
                == PostOperation(
                    action: .upscale(UpscaleOptions(target: .k4, frameRate: .keep, engine: .topaz)),
                    sourceJobID: "job-1"))
        #expect(try JSONDecoder().decode(PostOperation.self, from: cutout) == PostOperation(action: .removeBackground))
    }

    @Test func theNewOperationsKeepTheirStoredShape() throws {
        let stored = [
            #"{"action":{"reframe":{"_0":"9:16"}}}"#,
            #"{"action":{"dub":{"_0":"fra"}}}"#,
            #"{"action":{"changeVoice":{"_0":{"id":"v-1","type":"element","name":"Mine"}}}}"#,
        ]
        let expected: [PostAction] = [
            .reframe(.portrait), .dub(.french), .changeVoice(VoiceChoice(id: "v-1", type: "element", name: "Mine")),
        ]

        for (json, action) in zip(stored, expected) {
            let decoded = try JSONDecoder().decode(PostOperation.self, from: Data(json.utf8))
            #expect(decoded == PostOperation(action: action))
            #expect(try JSONDecoder().decode(PostOperation.self, from: JSONEncoder().encode(decoded)) == decoded)
        }
    }

    @Test(arguments: [
        ("https://cdn.example/a.MOV?sig=x", "mov"), ("https://cdn.example/a.webm", "webm"),
        ("https://cdn.example/a", "mp4"), ("https://cdn.example/a.mp4%2Fx", "mp4"),
        ("https://cdn.example/a.toolongext", "mp4"),
    ])
    func aResultKeepsItsOwnExtension(url: String, expected: String) throws {
        #expect(OutputNamePattern.resultExtension(of: try #require(URL(string: url))) == expected)
    }

    @Test func aFileNameTakesTheResultsExtension() {
        let job = Job(spec: Self.spec, providerKind: .account, cost: .unknownCredits)
        #expect(OutputNamePattern.standard.fileName(for: job, presetName: nil, fileExtension: "mov").hasSuffix(".mov"))
        #expect(OutputNamePattern.standard.fileName(for: job, presetName: nil).hasSuffix(".mp4"))
    }
}
