import Foundation
import Testing

@testable import Presentation

@Suite struct PromptHistoryTests {
    private func use(_ text: String, _ seconds: TimeInterval) -> PromptUse {
        PromptUse(text: text, date: Date(timeIntervalSince1970: seconds))
    }

    private func texts(_ items: [PromptHistoryItem]) -> [String] {
        items.map(\.text)
    }

    @Test func deduplicatesByTrimmedTextNewestFirstAndSkipsEmptyPrompts() {
        let items = PromptHistory.items(
            uses: [use("rainy neon", 10), use("clay", 20), use("  rainy neon\n", 30), use("   ", 40), use("", 50)],
            starred: [], clearedAt: nil)
        #expect(texts(items) == ["rainy neon", "clay"])
        #expect(items.first?.lastUsed == Date(timeIntervalSince1970: 30))
        #expect(items.allSatisfy { !$0.isStarred })
    }

    @Test func differentCaseIsADifferentPrompt() {
        let items = PromptHistory.items(uses: [use("Neon", 1), use("neon", 2)], starred: [], clearedAt: nil)
        #expect(texts(items) == ["neon", "Neon"])
    }

    @Test func equalDatesAreOrderedByText() {
        let items = PromptHistory.items(uses: [use("b", 5), use("a", 5)], starred: [], clearedAt: nil)
        #expect(texts(items) == ["a", "b"])
    }

    @Test func starredPromptsComeFirstMostRecentlyStarredFirst() {
        let items = PromptHistory.items(
            uses: [use("old", 1), use("mid", 2), use("new", 3)],
            starred: [use("old", 100), use(" mid ", 200)], clearedAt: nil)
        #expect(texts(items) == ["mid", "old", "new"])
        #expect(items.map(\.isStarred) == [true, true, false])
        #expect(items[0].lastUsed == Date(timeIntervalSince1970: 2))
    }

    @Test func clearingDropsUsesUpToTheDateButKeepsStarredPrompts() {
        let items = PromptHistory.items(
            uses: [use("before", 10), use("at", 20), use("after", 30), use("kept", 5)],
            starred: [use("kept", 6)], clearedAt: Date(timeIntervalSince1970: 20))
        #expect(texts(items) == ["kept", "after"])
        #expect(items[0].isStarred)
        #expect(items[0].lastUsed == nil)
    }

    @Test func aPromptUsedAgainAfterClearingReturns() {
        let items = PromptHistory.items(
            uses: [use("neon", 10), use("neon", 40)], starred: [], clearedAt: Date(timeIntervalSince1970: 20))
        #expect(items == [PromptHistoryItem(text: "neon", lastUsed: Date(timeIntervalSince1970: 40), isStarred: false)])
    }

    @Test func searchIgnoresCaseAndAccentsAndMatchesEveryWord() {
        let items = PromptHistory.items(
            uses: [use("Café at night, rainy", 3), use("Sunny beach", 2), use("night city", 1)],
            starred: [], clearedAt: nil)
        #expect(texts(PromptHistory.search(items, query: "CAFE")) == ["Café at night, rainy"])
        #expect(texts(PromptHistory.search(items, query: "night")) == ["Café at night, rainy", "night city"])
        #expect(texts(PromptHistory.search(items, query: " rainy  NIGHT ")) == ["Café at night, rainy"])
        #expect(PromptHistory.search(items, query: "snow").isEmpty)
    }

    @Test func emptySearchKeepsEverythingInOrder() {
        let items = PromptHistory.items(uses: [use("a", 1), use("b", 2)], starred: [use("a", 3)], clearedAt: nil)
        #expect(PromptHistory.search(items, query: "  \n") == items)
    }

    @Test func clearedAtIsUnsetUntilFirstClearing() {
        #expect(AppSettings.promptHistoryClearedAt(0) == nil)
        #expect(AppSettings.promptHistoryClearedAt(42) == Date(timeIntervalSince1970: 42))
    }
}
