import Testing

@testable import Presentation

@Suite struct WindowLifecycleTests {
    /// The main window and About.
    let appWindow = WindowLifecycle.Window(isPanel: false, isTitled: true, isShown: true)
    /// The menu bar panel, an alert, an open panel.
    let panel = WindowLifecycle.Window(isPanel: true, isTitled: true, isShown: true)
    /// The untitled windows AppKit and SwiftUI keep for themselves.
    let helper = WindowLifecycle.Window(isPanel: false, isTitled: false, isShown: true)

    @Test func aHiddenStartClosesEveryAppWindowOfTheLaunchAndNothingElse() {
        var start = HiddenStart()
        start.begin()
        #expect(start.closes(appWindow))
        // Not yet on screen as it reports itself.
        #expect(start.closes(WindowLifecycle.Window(isPanel: false, isTitled: true, isShown: false)))
        #expect(!start.closes(panel))
        #expect(!start.closes(helper))
    }

    /// Once the launch is over or the person asks for the window, ⌘N and the like open one as usual.
    @Test func windowsStayOnceTheHiddenStartEnds() {
        var start = HiddenStart()
        #expect(!start.closes(appWindow))
        start.begin()
        #expect(start.isActive)
        start.end()
        #expect(!start.isActive)
        #expect(!start.closes(appWindow))
    }

    @Test func onlyAShownAppWindowCountsAsOpen() {
        #expect(WindowLifecycle.isOpen(appWindow))
        #expect(!WindowLifecycle.isOpen(WindowLifecycle.Window(isPanel: false, isTitled: true, isShown: false)))
        #expect(!WindowLifecycle.isOpen(panel))
        #expect(!WindowLifecycle.isOpen(helper))
    }
}
