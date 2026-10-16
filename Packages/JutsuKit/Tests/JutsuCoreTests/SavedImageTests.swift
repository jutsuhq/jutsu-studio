import Foundation
import Testing

@testable import JutsuCore

struct SavedImageTests {
    private let date = Date(timeIntervalSince1970: 1_792_060_863)  // 2026-10-15 10:41:03 UTC
    private let utc = TimeZone(identifier: "UTC")!

    @Test func theNameStartsWithTheDateThenThePrompt() {
        #expect(
            SavedImage.baseName(prompt: "A knight in silver armor", createdAt: date, timeZone: utc)
                == "2026-10-15 10.41.03 A knight in silver armor")
    }

    @Test func aLongPromptIsCutAtAWord() {
        let prompt = "The Great Hall is grand and magical, with long wooden tables, floating candles and Gothic arches"
        let name = SavedImage.baseName(prompt: prompt, createdAt: date, timeZone: utc)
        #expect(name == "2026-10-15 10.41.03 The Great Hall is grand and magical, with long")
    }

    @Test func separatorsAndLeadingDotsDontReachTheFileName() {
        #expect(
            SavedImage.baseName(prompt: "..a/b:c\\d\nnext line", createdAt: date, timeZone: utc)
                == "2026-10-15 10.41.03 a-b-c-d next line")
        #expect(SavedImage.baseName(prompt: "   ", createdAt: date, timeZone: utc) == "2026-10-15 10.41.03")
    }
}
