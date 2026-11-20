import OverlayCore
import XCTest

final class OverlayAppearanceTests: XCTestCase {
    func testUsageColorThresholdsWithFakePercentages() {
        let examples: [(Int?, UsageLevel)] = [
            (nil, .normal), (0, .normal), (74, .normal),
            (75, .high), (89, .high),
            (90, .critical), (100, .critical),
        ]

        for (percent, expected) in examples {
            XCTAssertEqual(UsageLevel(percent: percent), expected, "Input: \(String(describing: percent))")
        }
    }

    func testTransparencyPresetsConvertToBackgroundOpacity() {
        XCTAssertEqual(BackgroundTransparency.allCases.map(\.rawValue), [0, 25, 50, 75, 100])
        XCTAssertEqual(BackgroundTransparency.allCases.map(\.opacity), [1, 0.75, 0.5, 0.25, 0])
    }

    func testSavedTransparencyDefaultsAndRestores() {
        XCTAssertEqual(BackgroundTransparency(savedPercent: nil), .quarter)
        XCTAssertEqual(BackgroundTransparency(savedPercent: 37), .quarter)
        XCTAssertEqual(BackgroundTransparency(savedPercent: 0), .opaque)
        XCTAssertEqual(BackgroundTransparency(savedPercent: 75), .threeQuarters)
        XCTAssertEqual(BackgroundTransparency(savedPercent: 100), .clear)
    }
}
