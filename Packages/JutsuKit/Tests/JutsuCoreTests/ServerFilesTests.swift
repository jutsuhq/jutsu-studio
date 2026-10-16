import Foundation
import Testing

@testable import JutsuCore

struct ServerFileNameTests {
    let folder = URL(fileURLWithPath: "/tmp/jutsu/motion-library", isDirectory: true)

    func file(_ names: [String], _ url: String, allowed: [String] = ServerFileName.videoExtensions) throws -> URL? {
        ServerFileName.file(in: folder, named: names, extensionOf: try #require(URL(string: url)), allowed: allowed)
    }

    @Test func plainNamesAreKept() throws {
        let placed = try #require(try file(["preset-1", "Dance Move"], "https://cdn.example/clip.MOV"))
        #expect(placed.path == "/tmp/jutsu/motion-library/preset-1/Dance Move.mov")
    }

    @Test func dotDotNamesStayInsideTheFolder() throws {
        let placed = try #require(try file(["..", "default"], "https://cdn.example/x.store"))
        #expect(placed.path == "/tmp/jutsu/motion-library/Untitled/default.mp4")
    }

    @Test func separatorsCannotClimbOut() throws {
        let placed = try #require(try file(["../../..", "..\\..\\evil", "a/../../b"], "https://cdn.example/x.mp4"))
        #expect(
            placed.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
                == folder.path)
        #expect(placed.path.hasPrefix(folder.path + "/"))
        #expect(!placed.pathComponents.dropFirst(folder.pathComponents.count).contains(".."))
    }

    @Test func extensionsOutsideTheAllowlistFallBack() throws {
        let images = ServerFileName.imageExtensions
        #expect(try file(["id"], "https://cdn.example/a.webp", allowed: images)?.pathExtension == "webp")
        #expect(try file(["id"], "https://cdn.example/a.HEIC", allowed: images)?.pathExtension == "heic")
        #expect(try file(["id"], "https://cdn.example/a.store", allowed: images)?.pathExtension == "jpg")
        #expect(try file(["id"], "https://cdn.example/a", allowed: images)?.pathExtension == "jpg")
    }

    @Test func emptyNamesGetAPlaceholder() throws {
        let placed = try file(["  ", "..."], "https://cdn.example/a.mp4")
        #expect(placed?.path == "/tmp/jutsu/motion-library/Untitled/Untitled.mp4")
    }

    @Test func containmentIsChecked() {
        #expect(ServerFileName.isInside(folder.appendingPathComponent("a.mp4"), folder))
        #expect(!ServerFileName.isInside(folder.appendingPathComponent("../a.mp4"), folder))
        #expect(!ServerFileName.isInside(folder, folder))
        #expect(!ServerFileName.isInside(URL(fileURLWithPath: "/tmp/jutsu/motion-library-2/a.mp4"), folder))
    }
}
