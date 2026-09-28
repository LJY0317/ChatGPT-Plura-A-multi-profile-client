import XCTest

final class ChatGPTPluraUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testRichContentUsesNativeCodeCard() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launchArguments.append("--ui-testing-rich-content")
        app.launch()

        XCTAssertTrue(app.navigationBars["Native Chat"].waitForExistence(timeout: 5))
        let transcript = app.collectionViews["chatTranscript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 3))

        let language = app.staticTexts["codeBlock.language"]
        for _ in 0..<8 where !language.exists {
            transcript.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(language.waitForExistence(timeout: 3))
        XCTAssertEqual(language.label, "SWIFT")

        let copy = app.buttons["codeBlock.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 3))
        XCTAssertEqual(copy.label, "Copy")
        copy.tap()
        XCTAssertTrue(app.buttons["codeBlock.copy"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["codeBlock.copy"].label, "Copied")

        let table = app.scrollViews["tableBlock"]
        for _ in 0..<8 where !table.exists {
            transcript.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(table.waitForExistence(timeout: 3))

        let activityTitle = app.staticTexts["activityCard.webSearch.title"]
        for _ in 0..<8 where !activityTitle.exists {
            transcript.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(activityTitle.waitForExistence(timeout: 3))
        XCTAssertEqual(activityTitle.label, "Web search")
        let activityMetadata = app.staticTexts["activityCard.webSearch.metadata"]
        XCTAssertTrue(activityMetadata.waitForExistence(timeout: 3))
        XCTAssertEqual(activityMetadata.label, "completed · 1.4s")
    }

    @MainActor
    func testStressScrollKeyboardStreamingAndRotation() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launchArguments.append("--scroll-diagnostics")
        app.launch()

        XCTAssertTrue(app.navigationBars["Native Chat"].waitForExistence(timeout: 5))

        let transcript = app.collectionViews["chatTranscript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))

        app.buttons["loadStress"].tap()
        let loadedPredicate = NSPredicate(format: "value BEGINSWITH %@", "2000|")
        expectation(for: loadedPredicate, evaluatedWith: transcript)
        waitForExpectations(timeout: 10)

        for _ in 0..<6 {
            transcript.swipeDown(velocity: .fast)
        }
        for _ in 0..<6 {
            transcript.swipeUp(velocity: .fast)
        }

        app.buttons["resetChat"].tap()

        let composer = app.textFields["composerField"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        composer.tap()
        composer.typeText("hello native")

        let sendButton = app.buttons["sendMessage"]
        XCTAssertTrue(sendButton.isEnabled)
        sendButton.tap()

        let streamingComplete = NSPredicate(
            format: "value CONTAINS %@",
            "official streaming endpoint"
        )
        expectation(for: streamingComplete, evaluatedWith: transcript)
        waitForExpectations(timeout: 8)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(transcript.waitForExistence(timeout: 3))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(transcript.waitForExistence(timeout: 3))
    }

    @MainActor
    func testPluraShellNavigationAndSettings() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing-plura-shell")
        app.launch()

        let menuButton = app.buttons["Open menu"]
        func revealSidebarIfNeeded() {
            if menuButton.waitForExistence(timeout: 1) {
                menuButton.tap()
            }
        }

        revealSidebarIfNeeded()
        let sidebarTitle = app.descendants(matching: .any).matching(identifier: "sidebarTitle").firstMatch
        XCTAssertTrue(sidebarTitle.waitForExistence(timeout: 3))
        XCTAssertEqual(sidebarTitle.label, "Plura Mobile")

        app.buttons["sidebarSurface.work"].tap()

        revealSidebarIfNeeded()
        XCTAssertTrue(app.buttons["sidebarSurface.codex"].waitForExistence(timeout: 3))
        app.buttons["sidebarSurface.codex"].tap()
        XCTAssertTrue(app.staticTexts["Codex"].waitForExistence(timeout: 3))

        revealSidebarIfNeeded()
        XCTAssertTrue(app.staticTexts["Connection"].waitForExistence(timeout: 3))
        app.staticTexts["Connection"].tap()
        XCTAssertTrue(app.navigationBars["Connection"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Done"].exists)

        let clearLog = app.buttons["Clear Remote Log"].firstMatch
        for _ in 0..<4 where !clearLog.exists {
            app.swipeUp()
        }
        XCTAssertTrue(clearLog.waitForExistence(timeout: 3))
        clearLog.tap()
        XCTAssertTrue(app.staticTexts["Clear remote diagnostics?"].waitForExistence(timeout: 3))
        let clearActions = app.buttons.matching(identifier: "Clear Remote Log").allElementsBoundByAccessibilityElement
        XCTAssertFalse(clearActions.isEmpty)
        let hittableClearAction = clearActions.first(where: \.isHittable)
        XCTAssertNotNil(hittableClearAction)
        hittableClearAction?.tap()

        app.buttons["Done"].tap()

        let searchButton = app.buttons["Search conversations"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 3))
        searchButton.tap()
        let searchField = app.searchFields["Search conversations"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
    }

    @MainActor
    func testMcpTypedFormValidationAndSubmit() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing-mcp-form")
        app.launch()

        XCTAssertTrue(app.staticTexts["Configure the test deployment"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["test-mcp"].exists)

        let name = app.textFields["mcpField.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))

        let submit = app.buttons["mcpElicitationSubmit"]
        XCTAssertTrue(submit.exists)
        XCTAssertFalse(submit.isEnabled)

        name.tap()
        name.typeText("Remote deploy")
        XCTAssertTrue(submit.isEnabled)
        submit.tap()

        XCTAssertTrue(app.staticTexts["MCP_FORM_SUBMITTED"].waitForExistence(timeout: 3))
    }
}
