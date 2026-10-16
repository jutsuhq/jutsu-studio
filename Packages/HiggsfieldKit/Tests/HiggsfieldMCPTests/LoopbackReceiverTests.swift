#if canImport(Network)
    import Foundation
    import Network
    import Testing

    @testable import HiggsfieldMCP

    @Test func requestTargetIsReadFromTheRequestLine() {
        let request = Data("GET /callback?code=c&state=s HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
        #expect(LoopbackReceiver.requestTarget(of: request) == "/callback?code=c&state=s")
        #expect(LoopbackReceiver.requestTarget(of: Data("POST /callback HTTP/1.1\r\n\r\n".utf8)) == nil)
        #expect(LoopbackReceiver.requestTarget(of: Data("garbage".utf8)) == nil)
    }

    @Test func errorRedirectShowsAFailurePage() throws {
        let failed = try #require(URL(string: "http://127.0.0.1:1/callback?error=access_denied&state=s"))
        let succeeded = try #require(URL(string: "http://127.0.0.1:1/callback?code=c&state=s"))
        #expect(CallbackPage().html(for: failed).contains("not completed"))
        #expect(CallbackPage().html(for: succeeded).contains("Access approved"))
    }

    @Test func thePageLinksBackToTheAppAndShowsItsIcon() throws {
        let succeeded = try #require(URL(string: "http://127.0.0.1:1/callback?code=c&state=s"))
        let page = CallbackPage(appURL: URL(string: "jutsustudio://"), iconPNG: Data([1, 2, 3]))
        let html = page.html(for: succeeded)
        #expect(html.contains(#"<a class="open" href="jutsustudio://">Open Jutsu Studio</a>"#))
        #expect(html.contains("data:image/png;base64,AQID"))
        #expect(!CallbackPage().html(for: succeeded).contains(#"class="open""#))
    }

    // Real sockets on 127.0.0.1, so these are serialized and use ports outside the registered ones.
    @Suite(.serialized, .timeLimit(.minutes(1))) struct LoopbackListener {
        @Test func aCallbackCanArriveInSeparateTCPWrites() async throws {
            let receiver = try await LoopbackReceiver.listen(onFirstFreeOf: [47_708])
            defer { receiver.stop() }
            receiver.redirects.expect(state: "s")
            let connection = NWConnection(host: "127.0.0.1", port: 47_708, using: .tcp)
            connection.start(queue: .global())
            defer { connection.cancel() }
            try await send(Data("GET /call".utf8), on: connection)
            try await Task.sleep(for: .milliseconds(100))
            try await send(Data("back?code=c&state=s HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8), on: connection)
            let callback = try await receiver.callback(timeout: .seconds(1))
            #expect(callback.query == "code=c&state=s")
        }

        private func send(_ data: Data, on connection: NWConnection) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(
                    content: data,
                    completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    })
            }
        }

        @Test func browserRedirectReachesTheAuthorizer() async throws {
            let presenter = LoopbackAuthorizationPresenter(ports: [47_701]) { url in
                // Stands in for the browser: the authorization server redirects to redirect_uri.
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let redirectURI = query.first { $0.name == "redirect_uri" }?.value ?? ""
                guard let callback = URL(string: redirectURI + "?code=the-code&state=s") else { return }
                Task { _ = try? await URLSession.shared.data(from: callback) }
            }

            let redirect = try await presenter.authorize { redirectURI in
                try #require(URL(string: "https://auth.example/authorize?redirect_uri=\(redirectURI)"))
            }

            #expect(redirect.redirectURI == "http://127.0.0.1:47701/callback")
            #expect(redirect.callback.absoluteString == "http://127.0.0.1:47701/callback?code=the-code&state=s")
        }

        @Test func aForgedCallbackIsRefusedAndTheGenuineOneStillArrives() async throws {
            let presenter = LoopbackAuthorizationPresenter(ports: [47_707]) { url in
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let redirectURI = query.first { $0.name == "redirect_uri" }?.value ?? ""
                guard let forged = URL(string: redirectURI + "?error=access_denied&state=forged"),
                    let genuine = URL(string: redirectURI + "?code=the-code&state=s")
                else { return }
                Task {
                    let refused = try? await URLSession.shared.data(from: forged)
                    #expect((refused?.1 as? HTTPURLResponse)?.statusCode == 400)
                    _ = try? await URLSession.shared.data(from: genuine)
                }
            }

            let redirect = try await presenter.authorize { redirectURI in
                try #require(URL(string: "https://auth.example/authorize?state=s&redirect_uri=\(redirectURI)"))
            }

            #expect(redirect.callback.absoluteString == "http://127.0.0.1:47707/callback?code=the-code&state=s")
        }

        @Test func aBrowserThatCannotOpenEndsTheSignIn() async throws {
            struct NoBrowser: Error {}
            let presenter = LoopbackAuthorizationPresenter(ports: [47_706]) { _ in throw NoBrowser() }
            await #expect(throws: NoBrowser.self) {
                _ = try await presenter.authorize { _ in try #require(URL(string: "https://auth.example/authorize")) }
            }
        }

        @Test func aBusyPortFallsBackToTheNextOne() async throws {
            let busy = try await LoopbackReceiver.listen(onFirstFreeOf: [47_702])
            defer { busy.stop() }
            let next = try await LoopbackReceiver.listen(onFirstFreeOf: [47_702, 47_703])
            defer { next.stop() }
            #expect(next.port == 47_703)
        }

        @Test func allPortsBusyIsReported() async throws {
            let busy = try await LoopbackReceiver.listen(onFirstFreeOf: [47_704])
            defer { busy.stop() }
            await #expect(throws: OAuthError.redirectUnavailable) {
                _ = try await LoopbackReceiver.listen(onFirstFreeOf: [47_704])
            }
        }

        @Test func cancellingStopsWaiting() async throws {
            let receiver = try await LoopbackReceiver.listen(onFirstFreeOf: [47_705])
            defer { receiver.stop() }
            let waiting = Task { try await receiver.callback() }
            waiting.cancel()
            await #expect(throws: CancellationError.self) { _ = try await waiting.value }
        }
    }
#endif
