import Foundation

public struct LocalImage: Codable, Sendable, Hashable {
    public var fileURL: URL
    /// Security-scoped bookmark of `fileURL`, so the sandbox lets a later launch read it.
    /// `nil` for jobs stored before bookmarks existed and where one couldn't be made.
    public var bookmark: Data?
    /// The `https:` link the image was downloaded from; `nil` for a file the user picked. Optional, so jobs,
    /// templates and drafts stored before it existed still decode.
    public var remoteOrigin: URL?
    /// The prompt the image was generated from in the app (Generate…); `nil` for any other image. Optional, so
    /// anything stored before it existed still decodes. Templates keep it with their copies.
    public var prompt: String?
    /// The media the provider already keeps of this exact file (an image of an account element), sent instead of
    /// an upload; `nil` for any other image. Optional, so anything stored before it existed still decodes.
    public var serverMedia: ServerMedia?
    public var material: MaterialReference?

    public init(
        fileURL: URL, bookmark: Data? = nil, remoteOrigin: URL? = nil, prompt: String? = nil,
        serverMedia: ServerMedia? = nil, material: MaterialReference? = nil
    ) {
        self.fileURL = fileURL
        self.bookmark = bookmark
        self.remoteOrigin = remoteOrigin
        self.prompt = prompt
        self.serverMedia = serverMedia
        self.material = material
    }
}
