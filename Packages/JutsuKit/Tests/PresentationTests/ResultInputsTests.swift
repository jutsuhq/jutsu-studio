import Foundation
import JutsuCore
import Testing

@testable import Presentation

@Suite struct ResultInputsTests {
    @Test func aLocalJobSavesItsOwnFiles() {
        let item = LibraryFixture.item(references: 2)
        let files = InputFile.all(in: item)
        #expect(files.map(\.title) == ["Source video", "Reference 1", "Reference 2"])
        #expect(files.allSatisfy { $0.local != nil && $0.remote == nil })
        #expect(files[0].fileName(base: item.sourceName) == "rooftop – Source.mov")
        #expect(files[2].fileName(base: item.sourceName) == "rooftop – Reference 2.png")
    }

    @Test func anAccountJobKeepsHiggsfieldsCopyAsAFallback() {
        var item = LibraryFixture.item(references: 2, via: .account)
        item.job.inputs = HistoryFixture.inputs
        let files = InputFile.all(in: item)
        #expect(
            files.map(\.remote) == [
                HistoryFixture.url("in.mp4"), HistoryFixture.url("a.png"), HistoryFixture.url("b.png"),
            ])
        #expect(files.allSatisfy { $0.local != nil })
    }

    @Test func aHistoryItemOnlyHasHiggsfieldsCopies() {
        let item = LibraryItemModel(history: HistoryFixture.item("gen-1"))
        let files = InputFile.all(in: item)
        #expect(files.count == 3)
        #expect(files.allSatisfy { $0.local == nil })
        #expect(files[0].remote == HistoryFixture.url("in.mp4"))
        #expect(files[1].fileName(base: "Genjutsu") == "Genjutsu – Reference 1.png")
    }

    @Test func fileNamesDropSlashesAndFallBackToTheKind() {
        let file = InputFile(role: .reference(3), local: nil, remote: URL(string: "https://cdn.example/media/abc"))
        #expect(file.fileName(base: "a/b: c") == "a-b- c – Reference 3.jpg")
        #expect(InputFile(role: .source, local: nil, remote: nil).fileName(base: " ") == "Result – Source.mp4")
        // A leading dot would make it a hidden file.
        #expect(file.fileName(base: ".x") == "x – Reference 3.jpg")
        #expect(file.fileName(base: " .. ") == "Result – Reference 3.jpg")
    }

    @Test func takenNamesGetANumber() {
        let taken: Set = ["/out/clip.mp4", "/out/clip 2.mp4"]
        let url = URL(fileURLWithPath: "/out/clip.mp4").unusedFileURL { taken.contains($0.path) }
        #expect(url.path == "/out/clip 3.mp4")
        #expect(URL(fileURLWithPath: "/out/new.mp4").unusedFileURL { taken.contains($0.path) }.path == "/out/new.mp4")
    }
}
