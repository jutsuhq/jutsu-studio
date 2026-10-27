import Foundation

/// The files of a model the app downloads itself, pinned to one revision of its repository, with what each file's
/// content hashes to.
public struct ModelManifest: Sendable, Hashable {
    public struct File: Sendable, Hashable {
        /// Relative to the repository and to the model's folder.
        public var path: String
        public var size: Int64
        /// SHA-256 of a file stored in Git LFS.
        public var sha256: String?
        /// Git's blob hash of a small file stored in Git itself: SHA-1 of "blob <size>\0" and the content.
        public var gitBlob: String?

        public init(path: String, size: Int64, sha256: String? = nil, gitBlob: String? = nil) {
            self.path = path
            self.size = size
            self.sha256 = sha256
            self.gitBlob = gitBlob
        }
    }

    /// "owner/name" on Hugging Face.
    public var repository: String
    /// The full commit hash every file is downloaded at.
    public var revision: String
    public var files: [File]

    public init(repository: String, revision: String, files: [File]) {
        self.repository = repository
        self.revision = revision
        self.files = files
    }

    public var size: Int64 { files.reduce(0) { $0 + $1.size } }

    /// Where a file is downloaded from: the pinned revision, never the newest.
    public func url(of file: File) -> URL? {
        let path = file.path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }
        return URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(path.joined(separator: "/"))")
    }
}

/// Parakeet Ultra: NVIDIA's Parakeet TDT 0.6B v3 post-trained by moondream, as a Core ML build by FluidInference, run
/// through FluidAudio. The app downloads it itself, at a pinned revision, only when the person asks in Settings.
public enum ParakeetUltra {
    public static let repository = "FluidInference/parakeet-ultra-coreml"
    public static let revision = "95eaa59a39d4394f047a4dc5cce480388a60d1b6"
    /// About what it takes in memory while it runs; a run is refused with less free.
    public static let memoryMB = 1500
    public static let license = "CC BY 4.0"
    public static let licenseURL = URL(string: "https://creativecommons.org/licenses/by/4.0/")
    public static let modelURL = URL(string: "https://huggingface.co/\(repository)/tree/\(revision)")
    /// The languages it hears, by code.
    public static let languages = [
        "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it", "lt", "lv", "mt", "nl", "pl",
        "pt",
        "ro", "ru", "sk", "sl", "sv", "uk",
    ]

    public static let manifest = ModelManifest(
        repository: repository, revision: revision,
        files: [
            .init(
                path: "Decoder.mlmodelc/analytics/coremldata.bin", size: 243,
                sha256: "fe92b6cfaa012abd5248c0bc877832f19807015abffc60d87b8ccc8ccb48b3b5"),
            .init(
                path: "Decoder.mlmodelc/coremldata.bin", size: 560,
                sha256: "3b06e66768f0df7e21795f50e2b29300e33eeb1a2579dc42c695279c2d308497"),
            .init(path: "Decoder.mlmodelc/model.mil", size: 13110, gitBlob: "36dcd5cbb71d13f42a177427ddbab7539e0d167e"),
            .init(
                path: "Decoder.mlmodelc/weights/weight.bin", size: 23604992,
                sha256: "02a0d219f281b9665bc10c8768649403b2eebbbf4b44c627041d948e0de11bb4"),
            .init(
                path: "Encoder.mlmodelc/analytics/coremldata.bin", size: 243,
                sha256: "d87101d824d6723cf95304da33755c3c60e762663b9ef2b0c4bd0aa166a09a0d"),
            .init(
                path: "Encoder.mlmodelc/coremldata.bin", size: 514,
                sha256: "397a84a4062f563cbc5f56077c674f09a61d85be5090f61d2f1932afb92ac0fe"),
            .init(
                path: "Encoder.mlmodelc/model.mil", size: 1002653, gitBlob: "8c5c9915fc71bb7e9b0be1e7b55e38ec6a007e7f"),
            .init(
                path: "Encoder.mlmodelc/weights/weight.bin", size: 594211328,
                sha256: "315ba01f33cadbf601d43ac7f5c86208b7aa75fdaa34705c9869d5abe3521c9b"),
            .init(
                path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", size: 243,
                sha256: "68d38ca646aebafa7a9329e2efda50f5767c49e89fdb5f77f212072bb66f97c4"),
            .init(
                path: "JointDecisionv3.mlmodelc/coremldata.bin", size: 592,
                sha256: "5e3af5a4ce686f6c237cadbd9284e10d333bc0e1546633cd0e430e6194044bc4"),
            .init(
                path: "JointDecisionv3.mlmodelc/model.mil", size: 11777,
                gitBlob: "be552d46f98f9dc9b242b0d1659833db60aa3f83"),
            .init(
                path: "JointDecisionv3.mlmodelc/weights/weight.bin", size: 12642764,
                sha256: "3f310b85b82341c53ec383025ab094a4e462ee1c592e1ad7c6bfe39cff66ca25"),
            .init(
                path: "Preprocessor.mlmodelc/analytics/coremldata.bin", size: 243,
                sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
            .init(
                path: "Preprocessor.mlmodelc/coremldata.bin", size: 486,
                sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
            .init(
                path: "Preprocessor.mlmodelc/metadata.json", size: 2841,
                gitBlob: "06162c58cf2f5343a0e60f36f843bcdf3cc58527"),
            .init(
                path: "Preprocessor.mlmodelc/model.mil", size: 28181,
                gitBlob: "f987e2479228436c49189aa47edb376db74dcff5"),
            .init(
                path: "Preprocessor.mlmodelc/weights/weight.bin", size: 491072,
                sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
            .init(path: "parakeet_vocab.json", size: 151122, gitBlob: "c684822ec3b671ebc449c433a7012398d39b8bb0"),
        ])
}
