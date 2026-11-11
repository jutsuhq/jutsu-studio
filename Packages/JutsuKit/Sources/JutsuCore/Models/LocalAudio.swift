import Foundation

/// The speech recording a model that voices characters takes (`VideoModelDescriptor.Control.speech`): one audio file
/// they say, which sets how long the clip runs.
public struct LocalAudio: Codable, Sendable, Hashable {
    /// A file on this Mac, or the link of one only the account holds (a generation made elsewhere).
    public var fileURL: URL
    /// Security-scoped bookmark of `fileURL`, so the sandbox lets a later launch read it; `nil` where one couldn't
    /// be made.
    public var bookmark: Data?
    /// Seconds the recording runs, read from the file when it was added; 0 when unknown (an imported generation
    /// whose recording wasn't downloaded).
    public var duration: TimeInterval

    public init(fileURL: URL, bookmark: Data? = nil, duration: TimeInterval) {
        self.fileURL = fileURL
        self.bookmark = bookmark
        self.duration = duration
    }

    /// The file's name, as the Create form and the agents show it.
    public var name: String { fileURL.lastPathComponent }
}
