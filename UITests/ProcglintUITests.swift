import AppKit

// XCUITest's runner requires XCTest; package unit tests continue to use Swift Testing.
import XCTest

@MainActor
final class ProcglintUITests: XCTestCase {
    func testSummaryAndProcessTable() throws {
        try withApp { app, _ in
            let window = app.windows["mainWindow"]
            XCTAssertTrue(window.waitForExistence(timeout: 10))
            for (card, value) in [("cpu", "25.0%"), ("memory", "4 GB"), ("pressure", "39%"), ("swap", "1 GB"), ("compressed", "512 MB"), ("battery", "69%")] {
                expectValue(window.staticTexts["summaryValue.\(card)"], equals: value)
            }
            XCTAssertTrue(window.staticTexts["Normal"].exists)
            XCTAssertTrue(window.staticTexts["of 8 GB"].exists)
            expectValue(window.staticTexts["batteryPower"], equals: "Using 33.1 W")
            expectValue(window.staticTexts["Charging · 1:53 to full"], equals: "Charging · 1:53 to full")
            let powerColumn = window.tables["processTable"].descendants(matching: .any)["column.power"]
            XCTAssertTrue(powerColumn.waitForExistence(timeout: 5))
            expectValue(powerColumn, equals: "Power")
            for identifier in ["systemCPUChart", "systemMemoryChart", "systemPressureChart", "systemPowerChart"] {
                let chart = window.descendants(matching: .any)[identifier]
                XCTAssertTrue(chart.waitForExistence(timeout: 5))
                XCTAssertGreaterThan(chart.frame.width, 100)
                XCTAssertEqual(chart.frame.height, 38, accuracy: 1)
            }
            expectValue(window.staticTexts["processCount"], equals: "20 of 20 processes")
            XCTAssertEqual(window.tables["processTable"].tableRows.count, 20)
            XCTAssertGreaterThan(window.tables["processTable"].frame.height, 200)
        }
    }

    func testHoverSharesCursorReadoutAcrossHeaderAndInspectorCharts() throws {
        try withApp { app, _ in
            search("4100", in: app)
            app.staticTexts["process.4100.name"].click()
            let cpu = app.descendants(matching: .any)["systemCPUChart"]
            let memory = app.descendants(matching: .any)["systemMemoryChart"]
            XCTAssertTrue(cpu.waitForExistence(timeout: 5), app.windows["mainWindow"].debugDescription)
            cpu.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).hover()
            let cursor = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Cursor:", "GiB"), object: memory)
            XCTAssertEqual(XCTWaiter.wait(for: [cursor], timeout: 10), .completed,
                           "CPU: \(cpu.label); Memory: \(memory.label); Latest: \(String(describing: memory.value))")
            wait(for: NSPredicate(format: "label CONTAINS %@", "Cursor:"), on: app.descendants(matching: .any)["systemPressureChart"])
            wait(for: NSPredicate(format: "label CONTAINS %@", "Cursor: 1.0 MiB"), on: app.descendants(matching: .any)["processMemoryChart"])
            wait(for: NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Cursor:", " W"), on: app.descendants(matching: .any)["systemPowerChart"])
            wait(for: NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Cursor:", " W"), on: app.descendants(matching: .any)["processPowerChart"])
            XCTAssertEqual(memory.value as? String, "4.0 GiB")
            app.searchFields["processSearch"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
            wait(for: NSPredicate(format: "NOT (label CONTAINS %@)", "Cursor:"), on: memory)
        }
    }

    func testInspectorCanCollapseAndExpand() throws {
        try withApp { app, _ in
            let inspector = app.descendants(matching: .any)["processInspector"]
            XCTAssertTrue(inspector.waitForExistence(timeout: 10))
            XCTAssertGreaterThan(inspector.frame.width, 300)
            app.buttons["toggleInspector"].click()
            wait(for: NSPredicate { _, _ in !inspector.exists || inspector.frame.width < 1 }, on: inspector)
            app.buttons["toggleInspector"].click()
            wait(for: NSPredicate { _, _ in inspector.exists && inspector.frame.width > 300 }, on: inspector)
        }
    }

    func testNameAndPIDSearch() throws {
        try withApp { app, _ in
            search("ALPHA", in: app)
            expectValue(app.staticTexts["processCount"], equals: "1 of 1 processes")
            expectValue(app.staticTexts["process.4100.name"], equals: "Alpha Worker")
            assertListGeometry(in: app)
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
            expectValue(app.staticTexts["process.4117.power"], equals: "—")
            app.staticTexts["process.4117.name"].click()
            expectValue(app.staticTexts["processIdentity"], contains: "PID 4117 · fixture-user (uid 501)")
            search("4118", in: app)
            expectValue(app.staticTexts["process.4118.cpu"], equals: "—")
            expectValue(app.staticTexts["process.4118.power"], equals: "—")
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
            assertListGeometry(in: app)
            expectValue(app.staticTexts["launchedBy"], equals: "Launched by")
            let root = app.descendants(matching: .any)["ancestor.1"]
            XCTAssertTrue(root.waitForExistence(timeout: 5), app.windows["mainWindow"].debugDescription)
            XCTAssertEqual(root.label, "launchd (1)")
            XCTAssertEqual(app.descendants(matching: .any)["ancestor.4101"].label, "Fixture Terminal (4101)")
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
            search("4100", in: app)
            app.staticTexts["process.4100.name"].click()
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
            XCTAssertTrue(settings.staticTexts["commandLineWarning"].exists)
            settings.checkBoxes["include_command_lines"].click()
            app.typeKey("0", modifierFlags: .command)
            expectValue(app.staticTexts["processCommandLine"], equals: "Command lines hidden — enable in Settings")
        }
    }

    func testSettingsRegistrationApprovalAndUnregistration() throws {
        try withApp(arguments: ["--ui-testing-unregistered", "--ui-testing-requires-approval"]) { app, _ in
            let main = app.windows["mainWindow"]
            XCTAssertTrue(main.waitForExistence(timeout: 10))
            let banner = main.descendants(matching: .any)["agentOnboardingBanner"]
            let card = main.descendants(matching: .any)["summaryCard.cpu"]
            XCTAssertLessThanOrEqual(banner.frame.maxY, card.frame.minY)
            main.buttons["registerAgent"].click()
            expectValue(main.staticTexts["agentOnboardingDetail"], contains: "Allow procglint")
            XCTAssertFalse(main.buttons["registerAgent"].exists)
            app.typeKey(",", modifierFlags: .command)
            let settings = app.windows["settingsWindow"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            let status = settings.descendants(matching: .any)["agentRegistrationStatus"]
            expectValue(status, contains: "Approval required")
            XCTAssertFalse(settings.buttons["settingsRegisterAgent"].isEnabled)
            XCTAssertTrue(settings.buttons["settingsUnregisterAgent"].isEnabled)
            settings.buttons["settingsLoginItems"].click()
            expectValue(status, contains: "Connected")
            wait(for: NSPredicate(format: "exists == false"), on: banner)
            settings.buttons["settingsUnregisterAgent"].click()
            expectValue(status, contains: "Not registered")
            wait(for: NSPredicate(format: "enabled == true"), on: settings.buttons["settingsRegisterAgent"])
            XCTAssertFalse(settings.buttons["settingsUnregisterAgent"].isEnabled)
            settings.buttons["settingsRegisterAgent"].click()
            expectValue(status, contains: "Approval required")
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

    private func assertListGeometry(in app: XCUIApplication) {
        let scroll = app.scrollViews["processScroll"]
        let count = app.staticTexts["processCount"]
        let nameHeader = app.tables["processTable"].descendants(matching: .any)["column.name"]
        let row = app.staticTexts["process.4100.name"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(scroll.frame.height, 200)
        XCTAssertGreaterThan(nameHeader.frame.height, 10)
        XCTAssertLessThanOrEqual(nameHeader.frame.maxY, row.frame.minY)
        XCTAssertLessThan(row.frame.maxY, count.frame.minY)
        XCTAssertLessThanOrEqual(scroll.frame.maxY, count.frame.minY + 2)
        XCTAssertTrue(row.isHittable)
    }

    private func expectValue(_ element: XCUIElement, equals value: String) {
        wait(for: NSPredicate(format: "value == %@ OR label == %@", value, value), on: element)
    }

    private func expectValue(_ element: XCUIElement, contains value: String) {
        wait(for: NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", value, value), on: element)
    }

    private func wait(for predicate: NSPredicate, on element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed, "\(predicate) on \(element)")
    }
}
