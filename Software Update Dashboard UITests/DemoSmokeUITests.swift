import JTKitUITestSupport
import XCTest

/// The release check's UI smoke tests, in demo mode: the same sample
/// Blueprints every run, no tenant, nothing saved. Run one at a time by
/// `Scripts/release-check.sh`; minutes, not hours.
final class DemoSmokeUITests: JTKitUITestCase {
    private let iPadBlueprint = "Contoso – iPad Update"
    private let macBlueprint = "Contoso – Mac Update"

    override var appName: String { "Software Update Dashboard" }

    override func launchApp() {
        launchInDemo()
    }

    override func didLaunch() {
        let main = app.windows.firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 20), "The main window did not open")
        if main.frame.width < 1300 {
            let zoom = app.menuBars.menuItems["Zoom"].firstMatch
            if zoom.exists { zoom.click() }
        }
    }

    /// The overview lists both sample Blueprints with their progress.
    func test1Overview() {
        XCTAssertTrue(window(titled: "Overview").waitForExistence(timeout: 20), "The overview did not open")
        XCTAssertTrue(app.outlines.staticTexts[iPadBlueprint].waitForExistence(timeout: 20), "The iPad Blueprint isn't in the sidebar")
        XCTAssertTrue(app.outlines.staticTexts[macBlueprint].exists, "The Mac Blueprint isn't in the sidebar")
        XCTAssertTrue(anyContaining("updatable on target").waitForExistence(timeout: 30), "The overview shows no progress")
    }

    func test2About() {
        checkAbout()
    }

    func test3SettingsTabs() {
        checkSettingsTabs(["Connections", "Updates"])
    }

    func test4ConnectionsEditor() {
        // Made-up values: the connection lives only in this run's in-memory list.
        checkConnectionsEditor { settings in
            let fields = settings.textFields.allElementsBoundByIndex
            guard let index = fields.firstIndex(where: { ($0.placeholderValue ?? "") == "From Jamf Account" }) else {
                return XCTFail("No Environment ID field")
            }
            self.type(UUID().uuidString, into: fields[index])
            if index + 1 < fields.count { self.type("jtktest-client", into: fields[index + 1]) }
            self.type("jtktest-secret", into: settings.secureTextFields.firstMatch)
        }
    }

    /// A Blueprint's dashboard: its rule, progress, categories and history.
    func test5Dashboard() {
        openBlueprint(iPadBlueprint)
        XCTAssertTrue(anyContaining("updatable devices on their target").waitForExistence(timeout: 30), "The dashboard shows no progress")
        XCTAssertTrue(anyContaining("Target unknown").exists, "The category cards are missing")
        XCTAssertTrue(any("History").exists, "The history is missing")
        XCTAssertTrue(anyContaining("so earlier counts don’t compare").exists, "The history's markers aren't listed")
    }

    /// A device's detail, then Inspect finds its likely cause.
    func test6DeviceInspect() {
        openBlueprint(iPadBlueprint)
        tap(app.radioButtons["Devices"].firstMatch, timeout: 10)
        tap(deviceRow("Field iPad 06"), timeout: 20)
        XCTAssertTrue(any("Reported by the device").waitForExistence(timeout: 10), "The deadline's source isn't shown")
        let inspect = app.buttons["Inspect"].firstMatch
        scrollIntoView(inspect)
        tap(inspect)
        XCTAssertTrue(any("Likely cause").waitForExistence(timeout: 30), "Inspect found no likely cause")
        XCTAssertTrue(app.buttons["Inspect Again"].waitForExistence(timeout: 10), "Inspect Again isn't offered")
    }

    /// Demo Situation › Apple's Release Data Unreachable: the refresh stops,
    /// the previous one stays with a banner; Sample Data brings it back.
    func test7AppleDataUnreachable() {
        openBlueprint(iPadBlueprint)
        XCTAssertTrue(anyContaining("updatable devices on their target").waitForExistence(timeout: 30), "The dashboard didn't load")
        chooseDemoSituation("Apple’s Release Data Unreachable")
        XCTAssertTrue(anyContaining("Apple’s release data couldn’t be read").waitForExistence(timeout: 30), "No banner says the refresh stopped")
        XCTAssertTrue(app.buttons["Try Again"].exists, "The banner has no Try Again")
        XCTAssertTrue(anyContaining("updatable devices on their target").exists, "The previous refresh isn't kept")
        chooseDemoSituation("Sample Data")
        XCTAssertTrue(waitForGone(anyContaining("Apple’s release data couldn’t be read")), "The banner stayed after Sample Data")
    }

    /// Demo Situation › Saved List Unreadable: the banner, then Start a New
    /// List empties the demo's list (in memory only).
    func test8UnreadableList() {
        XCTAssertTrue(app.outlines.staticTexts[iPadBlueprint].waitForExistence(timeout: 20))
        chooseDemoSituation("Saved List Unreadable")
        XCTAssertTrue(anyContaining("couldn’t be read. A copy was kept").waitForExistence(timeout: 20), "The unreadable-list banner isn't shown")
        XCTAssertTrue(app.buttons["Show Copy in Finder"].exists, "The banner has no Show Copy in Finder")
        tap(app.buttons["Start a New List…"].firstMatch)
        tap(dialogButton("Start a New List"))
        XCTAssertTrue(waitForGone(app.outlines.staticTexts[iPadBlueprint]), "The list wasn't started anew")
        XCTAssertFalse(anyContaining("couldn’t be read. A copy was kept").exists, "The banner stayed")
    }

    /// Stop Tracking asks first, then removes the Blueprint (the demo's, in memory).
    func test9StopTracking() {
        openBlueprint(iPadBlueprint)
        tap(app.menuBars.menuBarItems["Blueprint"])
        tap(app.menuItems["Stop Tracking…"])
        XCTAssertTrue(anyContaining("Nothing changes in Jamf.").waitForExistence(timeout: 10), "The confirmation doesn't say Jamf is untouched")
        tap(dialogButton("Stop Tracking and Delete History"))
        XCTAssertTrue(waitForGone(app.outlines.staticTexts[iPadBlueprint]), "The Blueprint is still tracked")
        XCTAssertTrue(app.outlines.staticTexts[macBlueprint].exists, "The other Blueprint went too")
    }

    /// Both exports save a file: the device list as CSV and the summary.
    func test10Exports() throws {
        openBlueprint(iPadBlueprint)
        XCTAssertTrue(anyContaining("updatable devices on their target").waitForExistence(timeout: 30), "The dashboard didn't load")
        tap(app.menuBars.menuBarItems["Blueprint"])
        tap(app.menuItems["Export Device List as CSV…"])
        saveInTestFolder()
        let csv = try XCTUnwrap(waitForFile(ending: ".csv"), "The device list wasn't saved")
        XCTAssertTrue(try String(contentsOf: csv, encoding: .utf8).contains("Field iPad 06"), "The CSV doesn't list the devices")

        tap(app.menuBars.menuBarItems["Blueprint"])
        tap(app.menuItems["Export Summary…"])
        saveInTestFolder()
        let summary = try XCTUnwrap(waitForFile(ending: ".txt"), "The summary wasn't saved")
        XCTAssertTrue(try String(contentsOf: summary, encoding: .utf8).contains(iPadBlueprint), "The summary doesn't name the Blueprint")
    }

    func test11ActivityLog() {
        openBlueprint(iPadBlueprint)
        XCTAssertTrue(anyContaining("updatable devices on their target").waitForExistence(timeout: 30), "The dashboard didn't load")
        checkActivityLog()
    }

    func test12DemoTitles() {
        tap(app.menuBars.menuBarItems[appName])
        tap(app.menuItems["About \(appName)"])
        XCTAssertTrue(window(titled: "About \(appName)").waitForExistence(timeout: 10))
        app.typeKey("l", modifierFlags: [.command, .shift])
        XCTAssertTrue(window(titled: "Activity Log").waitForExistence(timeout: 10))
        openSettings()
        checkDemoTitles()
    }

    // MARK: Helpers

    /// Selects a tracked Blueprint in the sidebar; its window title follows.
    private func openBlueprint(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        openSidebar(name)
        XCTAssertTrue(window(titled: name).waitForExistence(timeout: 20), "\(name) didn't open", file: file, line: line)
    }

    /// Blueprint › Demo Situation › `situation`.
    private func chooseDemoSituation(_ situation: String) {
        tap(app.menuBars.menuBarItems["Blueprint"])
        tap(app.menuItems["Demo Situation"])
        tap(app.menuItems[situation])
    }

    /// The sandboxed app's Save panel opens in its own last folder: go to
    /// this test's folder first, so nothing lands among the user's files.
    private func saveInTestFolder() {
        XCTAssertTrue(app.buttons["OKButton"].firstMatch.waitForExistence(timeout: 15), "No Save panel opened")
        goToFolder(testFolder.path)
        saveInChosenFolder()
    }

    /// A device's name in the device table (SwiftUI exposes a text as its value).
    private func deviceRow(_ name: String) -> XCUIElement {
        // SwiftUI's Table is exposed as an outline, like the sidebar
        app.outlines.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", name, name)).firstMatch
    }

    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval = 20) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    /// The file a Save panel wrote into this test's folder.
    private func waitForFile(ending suffix: String, timeout: TimeInterval = 15) -> URL? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let files = (try? FileManager.default.contentsOfDirectory(at: testFolder, includingPropertiesForKeys: nil)) ?? []
            if let file = files.first(where: { $0.lastPathComponent.hasSuffix(suffix) }) { return file }
            sleep(1)
        }
        return nil
    }
}
