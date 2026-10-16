import Foundation
import Testing

@testable import HiggsfieldCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Test(arguments: [
    ("https://cdn.example/a.mp4", true), ("HTTPS://cdn.example/a.mp4", true), ("http://cdn.example/a.mp4", false),
    ("file:///Users/me/Movies/x.mov", false), ("ftp://cdn.example/a.mp4", false), ("data:video/mp4,abc", false),
])
func onlyHTTPSURLsCountAsServerFiles(string: String, isHTTPS: Bool) throws {
    let url = try #require(URL(string: string))
    #expect(url.isHTTPS == isHTTPS)
}

@Test func aLocalFileURLIsNotHTTPS() {
    #expect(!URL(fileURLWithPath: "/tmp/x.mov").isHTTPS)
}

private struct DownloadFailed: Error, Equatable {}

@Test func aMissingHTTPResponseThrowsTheCallersNetworkError() throws {
    #expect(throws: HiggsfieldError.network) { try HTTPURLResponse.required(nil) }
    #expect(throws: DownloadFailed()) { try HTTPURLResponse.required(nil, networkError: DownloadFailed()) }
    let url = try #require(URL(string: "https://cdn.example/a.mp4"))
    let response = try #require(HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil))
    #expect(try HTTPURLResponse.required(response).isSuccess)
}
