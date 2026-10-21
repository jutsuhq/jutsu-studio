import Foundation
import Testing

@testable import JutsuCore

@Suite struct VideoModelCatalogTests {
    /// Every entry of the shipped file is one this version runs; a typo would otherwise drop a model silently.
    @Test func theBundledCatalogReadsEveryEntry() throws {
        let url = try #require(JutsuCoreResources.modelsURL)
        let catalog = try VideoModelCatalog(data: Data(contentsOf: url))
        #expect(catalog.descriptors.count == catalog.entryCount)
        #expect(catalog == VideoModelCatalog.bundled)
        #expect(Set(catalog.descriptors.map(\.id)).count == catalog.descriptors.count)
    }

    /// The three models stored jobs, templates and settings name keep their IDs, order and behaviour.
    @Test func theFirstModelsKeepTheirIDsAndOrder() {
        let first: [VideoModel] = [.genjutsu, .seedance25, .klingMotionControl]
        let stored = VideoModel.allCases.filter(first.contains)
        #expect(stored == first)
        #expect(VideoModel.allCases.first == .genjutsu)
        #expect(stored.map(\.rawValue) == ["genjutsu", "seedance25", "klingMotionControl"])
        #expect(stored.map(\.title) == ["Genjutsu", "Seedance 2.5", "Kling 3.0"])
        #expect(stored.map(\.family) == ["Genjutsu", "Seedance", "Kling"])
        #expect(VideoModel.genjutsu.detail == "Higgsfield's own")
        #expect(VideoModel.genjutsu.offersDraft && VideoModel.seedance25.offersDraft)
        #expect(!VideoModel.klingMotionControl.offersDraft)
        #expect(VideoModel.seedance25.declares(.frames) && VideoModel.seedance25.declares(.bitrate))
        #expect(VideoModel.klingMotionControl.declares(.quality))
        #expect(VideoModel.klingMotionControl.declares(.characterOrientation))
        #expect(!VideoModel.genjutsu.declares(.videoBackground))
    }

    /// The endpoint is the first key that applies: the mode, frames, the quality, then media or none.
    @Test func endpointsComeFromTheCatalog() {
        let genjutsu = Mode.allCases.filter(VideoModel.genjutsu.serves).map {
            VideoModel.genjutsu.endpointID(for: $0, resolution: .p720, hasMedia: true)
        }
        #expect(
            genjutsu == [
                "higgsfield/genjutsu/motion-transfer/v1.0", "higgsfield/genjutsu/restyle/v1.0",
                "higgsfield/genjutsu/object-swap/v1.0",
            ])
        let seedance = VideoModel.seedance25
        #expect(
            seedance.endpointID(for: .extend, resolution: .p720, hasMedia: true, usesFrames: true)
                == "bytedance/seedance-2.5/video-extend")
        #expect(
            seedance.endpointID(for: .motionTransfer, resolution: .p720, hasMedia: true, usesFrames: true)
                == "bytedance/seedance-2.5/image-to-video")
        #expect(
            seedance.endpointID(for: .motionTransfer, resolution: .p720, hasMedia: true)
                == "bytedance/seedance-2.5/reference-to-video")
        #expect(
            seedance.endpointID(for: .motionTransfer, resolution: .p720, hasMedia: false)
                == "bytedance/seedance-2.5/text-to-video")
        let kling = VideoModel.klingMotionControl
        #expect(
            Resolution.standard.map { kling.endpointID(for: .motionTransfer, resolution: $0, hasMedia: true) } == [
                "kling-video/v3/motion-control/std", "kling-video/v3/motion-control/std",
                "kling-video/v3/motion-control/pro",
            ])
    }

    /// Every mode of every model an API key runs reaches an endpoint, and every endpoint is priced: `Pricing` refuses
    /// to load with a tariff of the catalog missing.
    @Test func everyModelsEndpointsArePriced() throws {
        for model in VideoModel.allCases where model.runsWithAPIKey {
            for mode in model.modes {
                for hasMedia in [true, false] {
                    let endpoint = model.endpointID(for: mode, resolution: .p720, hasMedia: hasMedia)
                    #expect(!endpoint.isEmpty, "\(model.rawValue) \(mode.rawValue)")
                }
            }
        }
        _ = try Pricing.bundled()
    }

    /// MiniMax H3 Max isn't in the public REST docs, nor is Genjutsu Lite's request schema: they have no endpoint, so
    /// no tariff, and run on the account only.
    @Test func aModelWithoutEndpointsRunsOnTheAccountOnly() throws {
        let max = try #require(VideoModel(rawValue: "minimaxH3MaxReference"))
        let lite = try #require(VideoModel(rawValue: "genjutsuLite"))
        #expect(!max.runsWithAPIKey)
        #expect(max.endpointID(for: .motionTransfer, resolution: .p768, hasMedia: true).isEmpty)
        #expect(max.accountModelID(for: .motionTransfer) == "minimax_h3_max")
        #expect(!Pricing.tariffs.contains { $0.0.isEmpty })
        #expect(VideoModel.allCases.filter { !$0.runsWithAPIKey } == [lite, max])
    }

    /// Genjutsu Lite: Genjutsu's request and draft for Motion and Swap (no Restyle) on models of its own, up to 15 s.
    @Test func genjutsuLiteIsGenjutsusSecondModel() throws {
        let lite = try #require(VideoModel(rawValue: "genjutsuLite"))
        #expect(VideoModel.allCases.prefix(2) == [.genjutsu, lite])
        #expect(lite.title == "Genjutsu Lite")
        #expect(lite.family == VideoModel.genjutsu.family)
        #expect(lite.modes == [.motionTransfer, .objectSwap])
        #expect(lite.descriptor.shape == .genjutsu)
        #expect(lite.offersDraft && lite.resolutions == Resolution.standard)
        #expect(lite.accountModelID(for: .motionTransfer) == "hf_mult_motion_control_flash")
        #expect(lite.accountModelID(for: .objectSwap) == "hf_mult_replace_object_flash")
        for mode in lite.modes {
            #expect(lite.limits(for: mode).duration == 4...15)
            #expect(lite.limits(for: mode).referenceImages == VideoModel.genjutsu.limits(for: mode).referenceImages)
        }
        // Genjutsu stays each of its modes' default.
        #expect(Mode.motionTransfer.defaultModel == .genjutsu && Mode.objectSwap.defaultModel == .genjutsu)
    }

    @Test func eachModeDefaultsToTheFirstModelServingIt() {
        #expect(Mode.allCases.map(\.defaultModel) == [.genjutsu, .genjutsu, .genjutsu, .seedance25, .seedance25])
    }

    @Test func theAccountModelsAreNamedByMode() {
        #expect(VideoModel.genjutsu.accountModelID(for: .motionTransfer) == "hf_mult_motion_control")
        #expect(VideoModel.genjutsu.accountModelID(for: .objectSwap) == "hf_mult_replace_object")
        #expect(VideoModel.genjutsu.accountModelID(for: .restyle) == nil)
        #expect(VideoModel.seedance25.accountModelID(for: .extend) == "seedance_2_5")
        #expect(VideoModel.klingMotionControl.accountModelID(for: .motionTransfer) == "kling3_0_motion_control")
    }

    // MARK: Compatibility

    /// A model is coded as its bare ID, exactly as the enum was.
    @Test func aModelIsCodedAsItsID() throws {
        let encoded = try JSONEncoder().encode([VideoModel.genjutsu, .seedance25, .klingMotionControl])
        #expect(String(decoding: encoded, as: UTF8.self) == #"["genjutsu","seedance25","klingMotionControl"]"#)
        let decoded = try JSONDecoder().decode(
            [VideoModel].self, from: Data(#"["klingMotionControl","seedance25","genjutsu"]"#.utf8))
        #expect(decoded == [.klingMotionControl, .seedance25, .genjutsu])
    }

    /// An ID the catalog doesn't have fails like an unknown enum case did, so lossy readers drop it.
    @Test func anUnknownModelDoesntDecode() {
        #expect(VideoModel(rawValue: "veo") == nil)
        #expect(VideoModel(rawValue: "seedance25") == .seedance25)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(VideoModel.self, from: Data(#""veo""#.utf8)) }
    }

    /// Jobs stored by earlier versions, one per model, decode unchanged and encode the same ID back.
    @Test(arguments: ["genjutsu", "seedance25", "klingMotionControl"])
    func aStoredJobKeepsItsModel(id: String) throws {
        let json = """
            {"mode":"motionTransfer","model":"\(id)","source":{"fileURL":"file:///tmp/in.mp4","duration":10,\
            "pixelSize":{"width":1280,"height":720},"range":[0,5],"allowsUpscale":false},"references":[],\
            "prompt":"","resolution":"720p","isDraft":false,"audio":"original"}
            """
        let spec = try JSONDecoder().decode(JobSpec.self, from: Data(json.utf8))
        #expect(spec.model.rawValue == id)
        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(spec)) as? [String: Any])
        #expect(object["model"] as? String == id)
    }

    /// Templates saved by earlier versions keep their model.
    @Test func aStoredTemplateKeepsItsModel() throws {
        let json = """
            {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Fox","createdAt":0,"mode":"motionTransfer",\
            "model":"klingMotionControl","references":[],"prompt":"","resolution":"1080p","audio":"mute"}
            """
        let template = try JSONDecoder().decode(JobTemplate.self, from: Data(json.utf8))
        #expect(template.model == .klingMotionControl)
        #expect(template.resolution == .p1080)
    }

    /// The cached server limits keep naming the models by ID; an unknown one is still dropped.
    @Test func cachedConstraintsKeepTheirModels() throws {
        let json = """
            {"entries":[{"model":"seedance25","mode":"motionTransfer","constraints":{"maxDuration":20}},\
            {"model":"veo","mode":"motionTransfer","constraints":{"maxDuration":8}}]}
            """
        let table = try JSONDecoder().decode(ModelConstraintTable.self, from: Data(json.utf8))
        #expect(table.entries.map(\.model) == [.seedance25])
        #expect(VideoModel.seedance25.limits(for: .motionTransfer, constraints: table).duration == 4...20)
    }

    // MARK: Reading the file

    /// An entry this version can't run (an unknown shape, mode or control, a reversed range) is left out and the
    /// others load; a repeated ID keeps the first.
    @Test func entriesThisVersionCantRunAreLeftOut() throws {
        func entry(_ id: String, _ extra: String = "") -> String {
            """
            {"id":"\(id)","family":"F","title":"\(id)","modes":["motionTransfer"],\
            "request":{"shape":"seedance","endpoints":{"default":"x/\(id)"}}\(extra)}
            """
        }
        let models = [
            entry("ok", #","limits":{"duration":[2,10],"referenceImages":[0,3]},"controls":["draft"]"#),
            entry("shape").replacingOccurrences(of: #""seedance""#, with: #""cinema""#),
            entry("mode").replacingOccurrences(of: "motionTransfer", with: "dance"),
            entry("control", #","controls":["camera"]"#),
            entry("range", #","limits":{"duration":[10,2]}"#),
            entry("ok", #","controls":["frames"]"#),
        ]
        let catalog = try VideoModelCatalog(data: Data(#"{"models":[\#(models.joined(separator: ","))]}"#.utf8))
        #expect(catalog.entryCount == 6)
        #expect(catalog.descriptors.map(\.id) == ["ok"])
        let model = try #require(catalog["ok"])
        #expect(model.duration == 2...10)
        #expect(model.referenceImages == 0...3)
        #expect(model.controls == [.draft])
        #expect(model.endpoints == ["default": "x/ok"])
        #expect(model.accountModels.isEmpty)
    }
}
