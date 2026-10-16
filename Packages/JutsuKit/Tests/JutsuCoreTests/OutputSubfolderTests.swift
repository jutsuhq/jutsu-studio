import Foundation
import Testing

@testable import JutsuCore

struct OutputSubfolderTests {
    private let output = URL(filePath: "/Users/me/Movies/Jutsu Studio", directoryHint: .isDirectory)

    @Test func eachKindHasAFolderOfItsOwnInsideTheOutputFolder() {
        let folders = OutputSubfolder.allCases.map { $0.url(in: output) }
        #expect(Set(folders.map(\.path)).count == OutputSubfolder.allCases.count)
        for folder in folders {
            #expect(folder.deletingLastPathComponent().path == output.path)
            #expect(folder.hasDirectoryPath)
        }
    }

    @Test func videosAndImagesKeepTheirFolderNames() {
        #expect(OutputSubfolder.videos.url(in: output).lastPathComponent == "Videos")
        #expect(OutputSubfolder.images.url(in: output).lastPathComponent == "Images")
    }
}
