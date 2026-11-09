import AppKit

// XCUITest's runner requires XCTest; package unit tests continue to use Swift Testing.
import XCTest

@MainActor
final class ProcglintUITests: XCTestCase {
    func testSummaryAndProcessTable() throws {
        try withApp { app, _ in
            let window = app.windows["mainWindow"]
            XCTAssertTrue(window.waitForExistence(timeout: 10))
            expectValue(window.staticTexts["systemSummary"], contains: "CPU 25.0%")
            expectValue(window.staticTexts["systemSummary"], contains: "Memory pressure: Normal · 39%")
            expectValue(window.staticTexts["systemSummary"], contains: "Used 4 GB of 8 GB · Swap 1 GB · Compressed 512 MB")
            for identifier in ["systemCPUChart", "systemMemoryChart", "systemPressureChart"] {
                let chart = window.images[identifier]
                XCTAssertTrue(chart.waitForExistence(timeout: 5))
                XCTAssertEqual(chart.frame.width, 160, accuracy: 1)
                XCTAssertEqual(chart.frame.height, 36, accuracy: 1)
            }
            expectValue(window.staticTexts["processCount"], equals: "20 of 20 processes")
            XCTAssertEqual(window.tables["processTable"].tableRows.count, 20)
        }
    }

    func testHoverSharesCursorReadoutAcrossHeaderAndInspectorCharts() throws {
        try withApp { app, _ in
            search("4100", in: app)
            app.staticTexts["process.4100.name"].click()
            let cpu = app.images["systemCPUChart"]
            let memory = app.images["systemMemoryChart"]
            XCTAssertTrue(cpu.waitForExistence(timeout: 5))
            cpu.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).hover()
            wait(for: NSPredicate(format: "title CONTAINS %@", "Cursor: 4.0 GiB"), on: memory)
            wait(for: NSPredicate(format: "title CONTAINS %@", "Cursor: 65%"), on: app.images["systemPressureChart"])
            wait(for: NSPredicate(format: "title CONTAINS %@", "Cursor: 1.0 MiB"), on: app.images["processMemoryChart"])
            XCTAssertEqual(memory.value as? String, "4.0 GiB")
            app.searchFields["processSearch"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
            wait(for: NSPredicate(format: "NOT (title BEGINSWITH %@)", "Cursor:"), on: memory)
        }
    }

    func testNameAndPIDSearch() throws {
        try withApp { app, _ in
            search("ALPHA", in: app)
            expectValue(app.staticTexts["processCount"], equals: "1 of 1 processes")
            expectValue(app.staticTexts["process.4100.name"], equals: "Alpha Worker")
            search("4119", in: app)
            expectValue(app.staticTexts["processCount"], equals: "1 of 1 processes")
            expectValue(app.staticTexts["process.4119.name"], equals: "Other User Worker")
            search("no-such-process", in: app)
            expectValue(app.staticTexts["processCount"], equals: "0 of 0 processes")
        }
    }

    func testMineAndAllFilters() throws {
        try withApp { app, _ in
            let filter = app.descendants(matching: .any)["processFilter"]
            XCTAssertTrue(filter.waitForExistence(timeout: 10))
            filter.descendants(matching: .any)["Mine"].click()
            expectValue(app.staticTexts["processCount"], equals: "19 of 19 processes")
            XCTAssertFalse(app.staticTexts["process.4119.name"].exists)
            filter.descendants(matching: .any)["All"].click()
            expectValue(app.staticTexts["processCount"], equals: "20 of 20 processes")
            XCTAssertTrue(app.staticTexts["process.4119.name"].exists)
        }
    }

    func testColumnHeaderSortsBothDirections() throws {
        try withApp { app, _ in
            let table = app.tables["processTable"]
            XCTAssertTrue(table.waitForExistence(timeout: 10))
            expectValue(app.staticTexts["processCount"], equals: "20 of 20 processes")
            let header = table.descendants(matching: .any)["column.name"]
            XCTAssertTrue(header.waitForExistence(timeout: 5))
            header.click()
            expectValue(table.tableRows.element(boundBy: 0).staticTexts["process.4100.name"], equals: "Alpha Worker")
            header.click()
            expectValue(table.tableRows.element(boundBy: 0).staticTexts["process.4109.name"], equals: "Worker 9")
        }
    }

    func testInspectorAndMissingMetrics() throws {
        try withApp { app, _ in
            search("4117", in: app)
            expectValue(app.staticTexts["process.4117.cpu"], equals: "—")
            app.staticTexts["process.4117.name"].click()
            expectValue(app.staticTexts["processIdentity"], contains: "PID 4117 · fixture-user (uid 501)")
            search("4118", in: app)
            expectValue(app.staticTexts["process.4118.cpu"], equals: "—")
            expectValue(app.staticTexts["process.4118.footprint"], equals: "—")
            app.staticTexts["process.4118.name"].click()
            expectValue(app.staticTexts["processIdentity"], contains: "Status: permission_denied")
            XCTAssertFalse(app.buttons["quitProcess"].isEnabled)
            search("4119", in: app)
            expectValue(app.staticTexts["process.4119.name"], equals: "Other User Worker")
            app.staticTexts["process.4119.name"].click()
            expectValue(app.staticTexts["processIdentity"], contains: "PID 4119 · other-user (uid 502)")
            XCTAssertFalse(app.buttons["quitProcess"].isEnabled)
        }
    }

    func testInspectorShowsLaunchedByAndRedactedCommandLine() throws {
        try withApp { app, _ in
            search("4100", in: app)
            app.staticTexts["process.4100.name"].click()
            expectValue(app.staticTexts["launchedBy"], equals: "Launched by")
            let root = app.buttons["ancestor.1"]
            XCTAssertTrue(root.waitForExistence(timeout: 5))
            XCTAssertEqual(root.title, "launchd (1)")
            XCTAssertEqual(app.buttons["ancestor.4101"].title, "Fixture Terminal (4101)")
            expectValue(app.staticTexts["processCommandLine"], equals: "Command: node server.js --token <redacted>")
            expectValue(app.staticTexts["processCwd"], contains: "/fixture/project")
            expectValue(app.staticTexts["ancestorCommand.4101"], contains: "--auth=<redacted>")
            XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "ui-secret")).firstMatch.exists)
        }
    }

    func testQuitCancelSendsNothingAndConfirmSendsOnce() throws {
        try withApp { app, audit in
            search("4100", in: app)
            let row = app.staticTexts["process.4100.name"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.click()
            let quit = app.buttons["quitProcess"]
            wait(for: NSPredicate(format: "enabled == true"), on: quit)
            quit.click()
            let cancel = app.buttons["cancelTermination"]
            XCTAssertTrue(cancel.waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "Unsaved data may be lost")).firstMatch.exists)
            cancel.click()
            wait(for: NSPredicate(format: "enabled == true"), on: quit)
            XCTAssertEqual(try String(contentsOf: audit, encoding: .utf8), "")
            quit.click()
            let confirm = app.buttons["confirmTermination"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            confirm.click()
            expectValue(app.staticTexts["terminationFeedback"], contains: "Signal sent; exit not confirmed")
            XCTAssertEqual(try String(contentsOf: audit, encoding: .utf8), "prepare 4100 term\nsignal 4100 term")
        }
    }

    func testSettingsCopyMCPConfigAndMenuBarToggle() throws {
        try withApp { app, _ in
            XCTAssertTrue(app.windows["mainWindow"].waitForExistence(timeout: 10))
            app.typeKey(",", modifierFlags: .command)
            let settings = app.windows["settingsWindow"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            NSPasteboard.general.clearContents()
            settings.buttons["copyMCPConfig"].click()
            expectValue(settings.staticTexts["settingsFeedback"], equals: "MCP config copied")
            let text = try XCTUnwrap(NSPasteboard.general.string(forType: .string))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let servers = try XCTUnwrap(object["mcpServers"] as? [String: [String: Any]])
            let command = try XCTUnwrap(servers["procglint"]?["command"] as? String)
            XCTAssertTrue(command.hasSuffix("/procglint-mcp"))
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: command))
            let toggle = settings.checkBoxes["menuBarToggle"]
            let status = app.statusItems["monitorStatusItem"]
            XCTAssertEqual(toggle.value as? Int, 0)
            XCTAssertFalse(status.exists)
            toggle.click()
            XCTAssertTrue(status.waitForExistence(timeout: 5))
            XCTAssertEqual(toggle.value as? Int, 1)
            toggle.click()
            wait(for: NSPredicate(format: "exists == false"), on: status)
            XCTAssertEqual(toggle.value as? Int, 0)
        }
    }

    func testUnregisteredBannerAndExplicitRegistration() throws {
        try withApp(arguments: ["--ui-testing-unregistered"]) { app, _ in
            let window = app.windows["mainWindow"]
            XCTAssertTrue(window.waitForExistence(timeout: 10))
            expectValue(window.staticTexts["agentOnboardingMessage"], contains: "needs its background agent")
            XCTAssertEqual(window.tables["processTable"].tableRows.count, 0)
            let register = window.buttons["registerAgent"]
            XCTAssertTrue(register.exists)
            XCTAssertFalse(window.buttons["agentLoginItems"].exists)
            register.click()
            expectValue(window.staticTexts["processCount"], equals: "20 of 20 processes")
            XCTAssertFalse(window.staticTexts["agentOnboardingMessage"].exists)
        }
    }

    func testAboutMenuAndLaunchAtLoginFixture() throws {
        try withApp { app, _ in
            XCTAssertTrue(app.windows["mainWindow"].waitForExistence(timeout: 10))
            // The application menu title is the process name, which differs between Xcode and release builds.
            app.menuBars.menuBarItems.element(boundBy: 1).click()
            let about = app.menuItems["About procglint"]
            XCTAssertTrue(about.waitForExistence(timeout: 5))
            app.typeKey(.escape, modifierFlags: [])
            app.typeKey(",", modifierFlags: .command)
            let settings = app.windows["settingsWindow"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            let toggle = settings.checkBoxes["launchAtLoginToggle"]
            XCTAssertEqual(toggle.value as? Int, 0)
            toggle.click()
            wait(for: NSPredicate(format: "value == 1"), on: toggle)
            toggle.click()
            wait(for: NSPredicate(format: "value == 0"), on: toggle)
        }
    }

    private func withApp(arguments: [String] = [], _ body: (XCUIApplication, URL) throws -> Void) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let audit = FileManager.default.temporaryDirectory.appendingPathComponent("procglint-ui-\(UUID().uuidString).log")
        app.launchArguments = ["--ui-testing"] + arguments
        app.launchEnvironment["PROCGLINT_UI_TEST_AUDIT_PATH"] = audit.path
        addTeardownBlock { @MainActor () async throws in
            app.terminate()
            try? FileManager.default.removeItem(at: audit)
        }
        app.launch()
        try body(app, audit)
    }

    private func search(_ text: String, in app: XCUIApplication) {
        app.activate()
        let field = app.searchFields["processSearch"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        field.typeText(text)
        expectValue(field, equals: text)
    }

    private func expectValue(_ element: XCUIElement, equals value: String) {
        wait(for: NSPredicate(format: "value == %@", value), on: element)
    }

    private func expectValue(_ element: XCUIElement, contains value: String) {
        wait(for: NSPredicate(format: "value CONTAINS %@", value), on: element)
    }

    private func wait(for predicate: NSPredicate, on element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed, "\(predicate) on \(element)")
    }
}
