import Foundation
import JutsuAgent
import Testing

@testable import Presentation

@Suite struct MenuBarModeTests {
    @Test func menuBarModeKeepsTheAppRunningWithNothingToDo() {
        #expect(MenuBarMode.keepsRunning(isOn: true, activeCount: 0))
        #expect(MenuBarMode.keepsRunning(isOn: true, activeCount: 2))
    }

    @Test func offTheLastWindowQuitsAsBeforeUnlessWorkRuns() {
        #expect(!MenuBarMode.keepsRunning(isOn: false, activeCount: 0))
        #expect(MenuBarMode.keepsRunning(isOn: false, activeCount: 1))
        #expect(MenuBarMode.keepsRunning(isOn: false, activeCount: 0, images: ImageWork(running: 1, waiting: 0)))
    }

    @Test func theWindowAHiddenStartClosesNeverQuitsTheApp() {
        #expect(MenuBarMode.keepsRunning(isOn: false, isStartingHidden: true, activeCount: 0))
    }

    @Test func theAppLeavesTheDockOnlyInMenuBarModeWithNoWindow() {
        #expect(MenuBarMode.dockPresence(isOn: true, hasWindow: false) == .accessory)
        #expect(MenuBarMode.dockPresence(isOn: true, hasWindow: true) == .regular)
        #expect(MenuBarMode.dockPresence(isOn: false, hasWindow: false) == .regular)
        #expect(MenuBarMode.dockPresence(isOn: false, hasWindow: true) == .regular)
    }

    @Test func theHelperAlwaysStartsTheAppHiddenAndLoginOnlyInMenuBarMode() {
        for isOn in [false, true] {
            #expect(MenuBarMode.startsHidden(.helper, isOn: isOn))
            #expect(!MenuBarMode.startsHidden(.person, isOn: isOn))
        }
        #expect(MenuBarMode.startsHidden(.login, isOn: true))
        #expect(!MenuBarMode.startsHidden(.login, isOn: false))
    }

    @Test func menuBarModeShowsTheExtraWhateverShowInMenuBarSays() {
        #expect(MenuBarMode.showsExtra(showInMenuBar: false, isOn: true))
        #expect(MenuBarMode.showsExtra(showInMenuBar: true, isOn: false))
        #expect(!MenuBarMode.showsExtra(showInMenuBar: false, isOn: false))
    }

    /// The extra sets `isInserted` again on every scene update: what menu bar mode forces is never written, so turning
    /// the mode on and off leaves Show in menu bar as the person set it.
    @Test func theExtraWritesOnlyWhatThePersonChanged() {
        var showInMenuBar = false
        func extraSets(_ isInserted: Bool, isOn: Bool) {
            showInMenuBar = MenuBarMode.showInMenuBar(
                afterInserting: isInserted, showInMenuBar: showInMenuBar, isOn: isOn)
        }
        extraSets(MenuBarMode.showsExtra(showInMenuBar: showInMenuBar, isOn: true), isOn: true)
        extraSets(true, isOn: true)
        #expect(!showInMenuBar)
        #expect(!MenuBarMode.showsExtra(showInMenuBar: showInMenuBar, isOn: false))

        // ⌘-dragged out of the menu bar.
        #expect(!MenuBarMode.showInMenuBar(afterInserting: false, showInMenuBar: true, isOn: true))
        #expect(!MenuBarMode.showInMenuBar(afterInserting: false, showInMenuBar: true, isOn: false))
        #expect(!MenuBarMode.showInMenuBar(afterInserting: false, showInMenuBar: false, isOn: true))
        #expect(MenuBarMode.showInMenuBar(afterInserting: true, showInMenuBar: true, isOn: false))
        #expect(MenuBarMode.showInMenuBar(afterInserting: true, showInMenuBar: false, isOn: false))
    }

    @Test func quittingStillAsksWhileWorkRunsWhateverTheMode() {
        // The panel's Quit goes through the same `applicationShouldTerminate` as ⌘Q.
        #expect(BackgroundPolicy.quitPrompt(activeCount: 2) != nil)
        #expect(BackgroundPolicy.quitPrompt(activeCount: 0) == nil)
    }
}

extension MenuBarModeTests {
    @Test func theHelpersArgumentMakesAHelperLaunchWhateverTheEventSays() {
        let helper = ["/Applications/Jutsu Studio.app/Contents/MacOS/Jutsu Studio", AgentProtocol.helperLaunchArgument]
        #expect(MenuBarMode.launch(arguments: helper, isLoginItem: false) == .helper)
        #expect(MenuBarMode.launch(arguments: helper, isLoginItem: true) == .helper)
        #expect(MenuBarMode.launch(arguments: [helper[0]], isLoginItem: true) == .login)
        #expect(MenuBarMode.launch(arguments: [helper[0]], isLoginItem: false) == .person)
    }
}
