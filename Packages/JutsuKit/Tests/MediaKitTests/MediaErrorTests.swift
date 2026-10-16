import Foundation
import MediaKit
import Testing

@Suite struct MediaErrorTests {
    /// A failed job shows the description, so it names sizes the way Finder does, never the case.
    @Test func aTooLargeVideoNamesItsSizeAndTheLimit() {
        let text = MediaError.tooLarge(byteCount: 220_000_000).localizedDescription
        let size = ByteCountFormatter.string(fromByteCount: 220_000_000, countStyle: .file)
        let limit = ByteCountFormatter.string(fromByteCount: MediaPreparer.fileLengthLimit, countStyle: .file)
        #expect(text.contains(size) && text.contains(limit))
        #expect(!text.contains("tooLarge"))
    }
}
