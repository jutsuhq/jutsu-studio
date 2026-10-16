import Foundation

/// The page the browser tab shows once the authorization server redirects to the app's loopback listener: the
/// outcome, the app's icon, and a button back to the app.
public struct CallbackPage: Sendable {
    /// Opens the app from the browser, through its URL scheme; `nil` leaves the button out.
    public var appURL: URL?
    /// The app icon as PNG; `nil` shows the signature gradient instead.
    public var iconPNG: Data?

    public init(appURL: URL? = nil, iconPNG: Data? = nil) {
        self.appURL = appURL
        self.iconPNG = iconPNG
    }

    public func html(for callback: URL) -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let failed = items.contains { $0.name == "error" }
        // The app still checks `state` and exchanges the code, so success here is only the approval.
        let title = failed ? "Sign-in was not completed" : "Access approved"
        let detail =
            failed
            ? "Return to Jutsu Studio to try again, or connect with an API key instead."
            : "Jutsu Studio is finishing the sign-in."
        let icon =
            iconPNG.map { #"<img src="data:image/png;base64,\#($0.base64EncodedString())" alt="">"# }
            ?? #"<div class="mark"></div>"#
        // A check or a cross, drawn so the page needs nothing from the network.
        let badge =
            failed
            ? #"<span class="badge fail"><svg viewBox="0 0 16 16"><path d="M5 5l6 6M11 5l-6 6"/></svg></span>"#
            : #"<span class="badge"><svg viewBox="0 0 16 16"><path d="M3.5 8.5l3 3 6-7"/></svg></span>"#
        let button =
            appURL.map {
                #"<a class="open" href="\#(Self.escaped($0.absoluteString))">\#(failed ? "Return to" : "Open") Jutsu Studio</a>"#
            } ?? ""
        return """
            <!doctype html><html lang="en"><head><meta charset="utf-8"><title>Jutsu Studio</title>
            <meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="dark">
            <style>\(Self.style)</style></head><body><main>
            <div class="icon">\(icon)\(badge)</div>
            <h1>\(title)</h1><p>\(detail)</p>\(button)
            <p class="hint">You can close this tab.</p>
            </main></body></html>
            """
    }

    private static let style = """
        *{box-sizing:border-box}
        body{margin:0;min-height:100vh;display:grid;place-items:center;padding:24px;color:#fff;
        background:#060607 radial-gradient(70% 55% at 50% -10%,rgba(139,92,246,.22),transparent 70%) no-repeat;
        font:15px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;
        -webkit-font-smoothing:antialiased}
        main{width:100%;max-width:400px;padding:44px 32px 32px;text-align:center;border-radius:24px;
        background:rgba(255,255,255,.035);border:1px solid rgba(255,255,255,.08);
        box-shadow:0 30px 90px rgba(0,0,0,.55)}
        .icon{position:relative;width:96px;height:96px;margin:0 auto 26px}
        .icon img{width:96px;height:96px;display:block}
        .mark{width:96px;height:96px;border-radius:22px;
        background:linear-gradient(135deg,#8b5cf6,#d946ef 55%,#f472b6)}
        .badge{position:absolute;right:-4px;bottom:-4px;width:32px;height:32px;border-radius:50%;
        display:grid;place-items:center;background:#d4ff2a;border:3px solid #0d0d0f}
        .badge svg{width:16px;height:16px;fill:none;stroke:#0b0b0c;stroke-width:2.2;
        stroke-linecap:round;stroke-linejoin:round}
        .badge.fail{background:#ff5f57}.badge.fail svg{stroke:#fff}
        h1{margin:0 0 8px;font-size:24px;font-weight:650;letter-spacing:-.015em}
        p{margin:0;color:rgba(255,255,255,.6)}
        .open{display:block;margin-top:30px;padding:13px 20px;border-radius:12px;background:#d4ff2a;
        color:#0b0b0c;font-weight:600;text-decoration:none;transition:filter .15s}
        .open:hover{filter:brightness(1.07)}.open:active{filter:brightness(.95)}
        .hint{margin-top:16px;font-size:13px;color:rgba(255,255,255,.38)}
        """

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }
}
