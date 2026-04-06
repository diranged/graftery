import XCTest

/// UI tests for the Graftery menu bar app.
/// The app launches with real configs but the tests focus on UI behavior
/// (menu appears, windows open) rather than runner functionality.
final class MenuBarTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    /// Verify the app launches and creates a status bar item.
    func testAppLaunchesWithMenuBarItem() throws {
        app.launch()
        // Wait for StatusBarController setup (1.5s delay in AppDelegate).
        sleep(3)

        let statusItems = app.menuBars.children(matching: .statusItem)
        XCTAssertGreaterThan(statusItems.count, 0,
            "App should create at least one menu bar status item")
    }

    /// Verify clicking the status bar item opens a menu.
    func testStatusBarItemOpensMenu() throws {
        app.launch()
        sleep(3)

        let statusItem = app.menuBars.children(matching: .statusItem).firstMatch
        XCTAssert(statusItem.waitForExistence(timeout: 5),
            "Status bar item should exist")
        statusItem.click()

        // The menu should contain at least the Quit item.
        // Use a broad search since our items use custom views/attributed titles.
        let quitItem = app.menuItems["Quit Graftery"]
        XCTAssert(quitItem.waitForExistence(timeout: 3),
            "Quit menu item should exist")
    }

    /// Verify the app doesn't open any windows on launch.
    func testNoWindowOnLaunch() throws {
        app.launch()
        sleep(3)

        // A menu-bar-only app should have no visible windows on launch.
        // (The launch banner is an NSPanel which may or may not count.)
        let windows = app.windows
        // Filter to real content windows (not utility panels).
        let contentWindows = windows.matching(
            NSPredicate(format: "title CONTAINS[c] 'Configuration' OR title CONTAINS[c] 'Setup'")
        )
        XCTAssertEqual(contentWindows.count, 0,
            "No configuration or setup windows should open on launch")
    }
}
