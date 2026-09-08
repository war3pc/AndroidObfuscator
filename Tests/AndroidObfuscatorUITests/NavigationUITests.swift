import XCTest

final class NavigationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
    }

    func testSidebarAndDashboardCardsChangePages() throws {
        assertPage("overview")

        for page in ["source", "apk", "retrace", "toolchain", "history", "about", "overview"] {
            clickButton("sidebar.\(page)")
            assertPage(page)
        }

        clickButton("dashboard.source")
        assertPage("source")

        clickButton("sidebar.overview")
        clickButton("dashboard.apk")
        assertPage("apk")

        clickButton("sidebar.overview")
        clickButton("dashboard.metric.tools")
        assertPage("toolchain")

        clickButton("sidebar.overview")
        clickButton("dashboard.metric.history")
        assertPage("history")

        clickButton("sidebar.overview")
        clickButton("dashboard.metric.apk-engine")
        assertPage("toolchain")

        clickButton("sidebar.overview")
        clickButton("dashboard.capability.source")
        assertPage("source")

        clickButton("sidebar.overview")
        clickButton("dashboard.capability.native")
        assertPage("source")

        clickButton("sidebar.overview")
        clickButton("dashboard.capability.apk")
        assertPage("apk")

        clickButton("sidebar.overview")
        clickButton("dashboard.capability.retrace")
        assertPage("retrace")
    }

    private func clickButton(_ identifier: String) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 3), "按钮不存在：\(identifier)")
        XCTAssertTrue(button.isEnabled, "按钮不可点击：\(identifier)")
        button.click()
    }

    private func assertPage(_ identifier: String) {
        XCTAssertTrue(
            app.descendants(matching: .any)["page.\(identifier)"].waitForExistence(timeout: 3),
            "页面未显示：\(identifier)"
        )
    }
}
