import XCTest

// Regression guard for the "console keyboard cannot be dismissed" bug (iPhone).
// A keyboard-accessory `.toolbar(placement: .keyboard)` does NOT render for a
// TextField nested in the panelTabs TabView, so the dismiss affordance is an
// inline button on the command row, gated on @FocusState. This test proves it
// actually renders at runtime (a plain compile is not sufficient — the previous
// toolbar-based attempt compiled but never appeared).
final class KeyboardDismissUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PYMOL_AUTOLOAD"] = "1ubq.cif"
        app.launchEnvironment["PYMOL_SKIP_GESTURE_HELP"] = "1"
        app.launchEnvironment["PYMOL_SKIP_FIRSTBOOT_THEME"] = "1"
        app.launchEnvironment["PYMOL_AUTOPANEL"] = "open"      // expand bottom panel
        app.launchEnvironment["PYMOL_AUTOTAB"] = "console"     // select Console tab
        app.launch()
    }

    func testConsoleKeyboardHasWorkingDismissButton() throws {
        // The command field carries the placeholder as its accessibility label.
        var field = app.textFields["Enter command…"]
        if !field.waitForExistence(timeout: 10) {
            field = app.textFields.firstMatch   // fallback if the placeholder glyph differs
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Command field not found")

        let dismiss = app.buttons["Dismiss keyboard"]
        XCTAssertFalse(dismiss.exists, "Dismiss button should be hidden before the field is focused")

        field.tap()   // focus → @FocusState becomes true → inline dismiss button appears

        XCTAssertTrue(dismiss.waitForExistence(timeout: 5),
                      "The 'Dismiss keyboard' button did not appear when the command field was focused")

        dismiss.tap()  // clears focus
        XCTAssertTrue(waitForDisappearance(dismiss, timeout: 5),
                      "The 'Dismiss keyboard' button should disappear after dismissing the keyboard")
    }

    private func waitForDisappearance(_ el: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !el.exists { return true }
            usleep(200_000)
        }
        return !el.exists
    }
}
