//
//  CVProgrammerUITests.swift
//  CVProgrammerUITests
//
//  Created by Luc Dandoy on 22/12/2025.
//

import XCTest

final class CVProgrammerUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testRBusMonitorShowsStatesAndLiveChanges() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--rbus-ui-testing")
        app.launch()

        XCTAssertTrue(app.otherElements["rbus.monitor"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Disconnected"].exists)

        let occupiedInput = app.descendants(matching: .any)["rbus.1.1"]
        let freeInput = app.descendants(matching: .any)["rbus.1.2"]
        let unknownInput = app.descendants(matching: .any)["rbus.1.3"]
        XCTAssertTrue(occupiedInput.waitForExistence(timeout: 2))
        XCTAssertTrue(occupiedInput.label.contains("Occupied"))
        XCTAssertTrue(freeInput.label.contains("Free"))
        XCTAssertTrue(unknownInput.label.contains("Unknown"))

        let changedToFree = NSPredicate(format: "label CONTAINS %@", "Free")
        expectation(for: changedToFree, evaluatedWith: occupiedInput)
        waitForExpectations(timeout: 5)
    }

    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }
}
