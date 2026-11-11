import Foundation
import JutsuCore
import Testing

@testable import Presentation

/// The speech recording a model that voices characters takes: offered and sent only on a model that declares it
/// (`VideoModelDescriptor.Control.speech`), kept with the inputs, and saved back with them.
@Suite struct SpeechInputTests {
    let speech = LocalAudio(fileURL: URL(fileURLWithPath: "/tmp/lines.mp3"), duration: 6.4)

    @Test func theCatalogReadsTheSpeechControl() throws {
        let json = """
            {"models": [{"id": "talker", "family": "Talker", "title": "Talker", "modes": ["motionTransfer"],
              "controls": ["clipWithoutSource", "speech"], "request": {"shape": "kling4", "endpoints": {}}}]}
            """
        let catalog = try VideoModelCatalog(data: Data(json.utf8))
        #expect(catalog["talker"]?.controls == [.clipWithoutSource, .speech])
    }

    /// No bundled model before Intone takes speech: Create hides it and the jobs carry none.
    @Test func aModelWithoutSpeechNeitherOffersNorSendsIt() {
        var form = CreateForm(mode: .motionTransfer, resolution: .p720)
        form.model = .seedance25
        form.prompt = "A fox runs through fresh snow"
        form.setSpeech(speech)

        #expect(!form.offersSpeech)
        #expect(form.speech == speech)
        #expect(form.makeSpecs(isDraft: false, in: CreateFixture.apiKey).map(\.speech) == [nil])
    }

    /// Intone offers Speech, sends it, and runs as long as it and 2.5 s more; Create says what is missing.
    @Test func intoneTakesTheSpeechAndRunsAsLongAsIt() throws {
        var form = CreateForm(mode: .motionTransfer, resolution: .p720)
        form.model = try #require(VideoModel(rawValue: "intone"))
        form.references = CreateFixture.references([CreateFixture.image(1)])
        #expect(form.offersSpeech && form.isWithoutSource)
        #expect(form.text(for: .speechRequired) == "Add a speech recording")

        form.setSpeech(speech)
        let specs = form.makeSpecs(isDraft: false, in: CreateFixture.apiKey)
        #expect(specs.map(\.speech) == [speech] && specs.map(\.duration) == [8.9])
        #expect(Validation.check(try #require(specs.first)).isEmpty)
        #expect(form.text(for: .speechTooLong(31)) == "Use a speech of at most 30 s")
    }

    @Test func editInputsAndTheSavedDraftKeepTheSpeech() throws {
        let spec = JobSpec(
            mode: .motionTransfer, model: .seedance25, source: nil, prompt: "talk", resolution: .p720, length: 8,
            aspectRatio: .landscape, speech: speech)
        var form = CreateForm(mode: .motionTransfer, resolution: .p720)
        form.load(spec, source: nil)
        #expect(form.speech == speech)

        let decoded = try JSONDecoder().decode(CreateForm.self, from: JSONEncoder().encode(form))
        #expect(decoded.speech == speech)
        let job = try JSONDecoder().decode(JobSpec.self, from: JSONEncoder().encode(spec))
        #expect(job.speech == speech)
    }

    /// A job stored before speech existed has none, and its uploaded inputs no audio.
    @Test func jobsStoredBeforeSpeechDecodeWithoutOne() throws {
        let stored = JobSpec(mode: .motionTransfer, source: nil, resolution: .p720)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any])
        object["speech"] = nil
        let spec = try JSONDecoder().decode(JobSpec.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(spec.speech == nil)
        let inputs = try JSONDecoder().decode(RemoteInputs.self, from: Data(#"{"images": []}"#.utf8))
        #expect(inputs.audio == nil)
    }

    @Test func savingTheInputsIncludesTheSpeech() {
        var item = LibraryFixture.item(references: 1, via: .account)
        item.job.spec.speech = speech
        let uploaded = URL(string: "https://cdn.example/speech.mp3")
        item.job.inputs = RemoteInputs(
            video: nil, images: [], audio: uploaded.map { RemoteAsset(url: $0, id: "speech-1") })

        let files = InputFile.all(in: item)

        #expect(files.map(\.title) == ["Source video", "Reference 1", "Speech"])
        #expect(files.last?.local?.fileURL == speech.fileURL)
        #expect(files.last?.remote == uploaded)
        #expect(files.last?.fileName(base: item.sourceName) == "rooftop – Speech.mp3")
        #expect(InputFile(role: .speech, local: nil, remote: nil).fileName(base: "x") == "x – Speech.m4a")
    }

    @Test func anAgentsSpeechOnAModelWithoutItIsRefused() {
        let order = AgentVideoOrder(
            mode: "motion_transfer", model: "seedance25", prompt: "talk", length: 8, speech: speech)
        guard case .failure(let refusal) = order.spec(from: CreateForm(), in: CreateFixture.apiKey) else {
            Issue.record("The order was accepted")
            return
        }
        #expect(refusal.message == "Seedance 2.5 takes no speech; leave speech out.")
    }
}
