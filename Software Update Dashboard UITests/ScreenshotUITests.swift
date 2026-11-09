import JTKitUITestSupport
import XCTest

/// The README's and the website's screenshots, in demo mode (Contoso's
/// sample Blueprints, no real identifiers). Not part of the release check.
/// Run with
/// xcodebuild test -project "Software Update Dashboard.xcodeproj" -scheme "Software Update Dashboard Release Check"
///   -only-testing:"Software Update Dashboard UITests/ScreenshotUITests"
/// and export the attachments (xcrun xcresulttool export attachments),
/// scaled to 1800 pixels wide, to docs/screenshot.png (the dashboard) and
/// docs/screenshot-overview.png and docs/screenshot-devices.png.
final class ScreenshotUITests: JTKitUITestCase {
    override var appName: String { "Software Update Dashboard" }

    override func setUpWithError() throws {
        try XCTSkipIf(Self.isReleaseCheck, "Screenshots aren't part of the release check")
        try super.setUpWithError()
    }

    override func launchApp() {
        launchInDemo(arguments: ["-AppleLanguages", "(en-US)", "-AppleLocale", "en_US"])
    }

    override func didLaunch() {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "The main window did not open")
        tap(app.menuBars.menuBarItems["Window"])
        tap(app.menuItems["Zoom"])
        sleep(2)
    }

    func testScreenshots() {
        let main = app.windows.firstMatch
        XCTAssertTrue(anyContaining("updatable on target").waitForExistence(timeout: 30), "The overview shows no progress")
        keep(main.screenshot(), named: "screenshot-overview")

        openSidebar("Contoso – iPad Update")
        XCTAssertTrue(anyContaining("updatable devices on their target").waitForExistence(timeout: 30), "The dashboard didn't load")
        sleep(2)
        // the README's, and the website's dashboard
        keep(main.screenshot(), named: "screenshot")

        tap(app.radioButtons["Devices"].firstMatch, timeout: 10)
        tap(deviceRow("Field iPad 06"), timeout: 20)
        let inspect = app.buttons["Inspect"].firstMatch
        scrollIntoView(inspect)
        tap(inspect)
        XCTAssertTrue(any("Likely cause").waitForExistence(timeout: 30), "Inspect found no likely cause")
        sleep(1)
        keep(main.screenshot(), named: "screenshot-devices")
    }

    /// A device's name in the device table (SwiftUI exposes a text as its value).
    private func deviceRow(_ name: String) -> XCUIElement {
        // SwiftUI's Table is exposed as an outline, like the sidebar
        app.outlines.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", name, name)).firstMatch
    }

    private func keep(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
