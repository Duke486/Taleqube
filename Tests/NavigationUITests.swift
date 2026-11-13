import XCTest
import UIKit
import AppIntents

final class NavigationUITests: XCTestCase {
    @MainActor func testCloudSettingsEntryAndDefaults() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier:"app.anishelf.personal")
        app.launch()
        let settings = app.buttons["sidebar.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout:20))
        settings.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout:5))
        app.buttons["数据"].firstMatch.tap()
        let cloud = app.buttons["S3 云同步"].firstMatch
        XCTAssertTrue(cloud.waitForExistence(timeout:5)); cloud.tap()
        XCTAssertTrue(app.navigationBars["S3 云同步"].waitForExistence(timeout:5))
        XCTAssertTrue(app.textFields["Endpoint"].exists)
        XCTAssertTrue(app.secureTextFields["Secret Key"].exists)
        XCTAssertTrue(app.switches["TLS 证书验证"].exists)
        app.swipeUp()
        XCTAssertTrue(app.buttons["测试连接与读写"].waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons["立即同步"].exists)
        let screenshot = XCTAttachment(screenshot:app.screenshot())
        screenshot.name = "Cloud synchronization settings"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    @MainActor func testPhonePlatformEntries() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("iPhone navigation") }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier:"app.anishelf.personal")
        app.launch()
        let library = app.tabBars.buttons["资料库"]
        XCTAssertTrue(library.waitForExistence(timeout:15))
        library.tap()
        for (source,title) in [("anilist","AniList"),("trakt","Trakt")] {
            let entry = app.buttons["library.platform." + source]
            XCTAssertTrue(entry.waitForExistence(timeout:5))
            XCTAssertTrue(entry.isHittable)
            entry.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout:5))
            app.navigationBars[title].buttons.firstMatch.tap()
        }
    }

    @MainActor func testOpeningWorkDetailRemainsVisible() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier:"app.anishelf.personal")
        app.launch()
        XCTAssertTrue(app.wait(for:.runningForeground,timeout:15))
        let card = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","work.open.")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout:20),"A work card must be available to exercise detail creation")
        card.tap()
        let close = app.buttons["关闭详情"]
        XCTAssertTrue(close.waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["简介"].firstMatch.waitForExistence(timeout:10),"Detail content must finish creating its view metadata")
        let disappeared = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in
            app.state != .runningForeground || !close.exists
        },object:nil)
        disappeared.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for:[disappeared],timeout:6),.completed,"Detail must remain alive through metadata updates")
        let screenshot = XCTAttachment(screenshot:app.screenshot())
        screenshot.name = "Work detail opened"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    @MainActor func testNavigationRemainsUsableAcrossPlacements() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier:"app.anishelf.personal")
        app.launch()
        XCTAssertTrue(app.wait(for:.runningForeground,timeout:15))
        XCTAssertTrue(app.scrollViews.firstMatch.waitForExistence(timeout:10),"Startup must render page content")
        print("NAVIGATION_INITIAL\n" + app.debugDescription)
        let screenshot = XCTAttachment(screenshot:app.screenshot())
        screenshot.name = "Navigation initial"; screenshot.lifetime = .keepAlways; add(screenshot)
        // The system toggle stays at the leading edge of the native tab/sidebar.
        let toggles = app.buttons.matching(NSPredicate(format:"identifier == 'ToggleSidebar' OR identifier == 'ToggleSideBar'"))
        XCTAssertTrue(toggles.firstMatch.waitForExistence(timeout:10),app.debugDescription)
        let home = app.buttons.matching(NSPredicate(format:"label == %@","首页")).firstMatch
        XCTAssertTrue(home.waitForExistence(timeout:5))
        home.tap()
        let refresh = app.buttons["workspace.refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout:5),"The page toolbar must be hosted by the native navigation bar")
        let toolbarY = refresh.frame.midY
        toggles.firstMatch.tap()
        XCTAssertTrue(app.scrollViews.firstMatch.waitForExistence(timeout:5),"Changing placement must retain page content")
        XCTAssertTrue(refresh.waitForExistence(timeout:5))
        XCTAssertEqual(refresh.frame.midY,toolbarY,accuracy:2,"Sidebar collapse must not move the toolbar to a second row")
        XCTAssertEqual(app.buttons["sidebar.settings"].frame.midY,refresh.frame.midY,accuracy:2)
        XCTAssertEqual(app.buttons["sidebar.deliveries"].frame.midY,refresh.frame.midY,accuracy:2)
        print("NAVIGATION_TOGGLED\n" + app.debugDescription)
        let toggled = XCTAttachment(screenshot:app.screenshot())
        toggled.name = "Navigation toggled"; toggled.lifetime = .keepAlways; add(toggled)
        for title in ["首页","发现","资料库","AniList","Trakt"] {
            let item = app.buttons.matching(NSPredicate(format:"label == %@",title)).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout:5),"Missing navigation: " + title + "\n" + app.debugDescription)
            XCTAssertTrue(item.isHittable,"Unreachable navigation: " + title)
            item.tap()
            XCTAssertTrue(app.scrollViews.firstMatch.waitForExistence(timeout:5),"Page content missing: " + title)
            if title == "发现" {
                XCTAssertTrue(app.textFields["搜索作品"].waitForExistence(timeout:5),"Discovery must actually become the selected page")
                app.textFields["搜索作品"].tap()
                app.textFields["搜索作品"].typeText("test")
            }
        }
        toggles.firstMatch.tap()
        XCTAssertTrue(app.buttons["sidebar.settings"].waitForExistence(timeout:5))
        app.buttons["sidebar.settings"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout:5),app.debugDescription)
        app.buttons["完成"].firstMatch.tap()
    }
}
