import XCTest
@testable import SlashCommandCore

final class PickerHeaderTests: XCTestCase {
    func testLongerModelNameIsNotTheWantedHeader() {
        XCTAssertFalse(Picker.header("Select Reasoning Level for GPT-6.1-Sol-Mini", matches: "Select Reasoning Level for GPT-6.1-Sol"))
    }

    func testSameHeaderMatches() {
        XCTAssertTrue(Picker.header("Select Reasoning Level for GPT-6.1-Sol", matches: "Select Reasoning Level for GPT-6.1-Sol"))
        XCTAssertTrue(Picker.header("Select model", matches: "Select model"))
    }

    func testHeaderMayContinueAfterAWordBoundary() {
        XCTAssertTrue(Picker.header("Select Reasoning Level for GPT-6-Astra", matches: "Select Reasoning Level"))
        XCTAssertTrue(Picker.header("Select model Switch between models.", matches: "Select model"))
    }

    func testLongerNameWithDigitsOrUnderscoreIsNotTheWantedHeader() {
        XCTAssertFalse(Picker.header("Select Reasoning Level for GPT-6.15", matches: "Select Reasoning Level for GPT-6.1"))
        XCTAssertFalse(Picker.header("Select Reasoning Level for GPT_6", matches: "Select Reasoning Level for GPT"))
    }
}
