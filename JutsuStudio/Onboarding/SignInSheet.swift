import AppKit
import Presentation
import SwiftUI

/// Progress while sign-in is open in the browser, with the page's link in case the browser didn't come up.
struct SignInSheet: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Finish signing in in your browser").font(.system(size: 16, weight: .bold))
            }
            Text(
                """
                Higgsfield's sign-in page is open. Approve access for Jutsu Studio and \
                you'll be brought back here automatically.
                """
            )
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let url {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Open Again", systemImage: "safari")
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .hoverHint("Copy sign-in link")
                }
                Spacer()
                Button("Cancel", role: .cancel) { connection.cancelSignIn() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(Theme.background)
        .buttonStyle(.secondaryAction)
    }

    private var url: URL? {
        if case .signingIn(let url) = connection.activity { url } else { nil }
    }
}
