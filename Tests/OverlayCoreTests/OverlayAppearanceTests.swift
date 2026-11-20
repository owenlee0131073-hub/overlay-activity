import OverlayCore
import XCTest

final class OverlayAppearanceTests: XCTestCase {
    func testCPUAndGPUGradientWithFakePercentages() {
        let examples: [(Int, UsageColor)] = [
            (-1, UsageColor(red: 0x77, green: 0xCA, blue: 0x9B)),
            (0, UsageColor(red: 0x77, green: 0xCA, blue: 0x9B)),
            (25, UsageColor(red: 0xA1, green: 0xC5, blue: 0x84)),
            (50, UsageColor(red: 0xCB, green: 0xC0, blue: 0x6C)),
            (75, UsageColor(red: 0xD3, green: 0x86, blue: 0x5C)),
            (100, UsageColor(red: 0xDC, green: 0x4C, blue: 0x4C)),
            (101, UsageColor(red: 0xDC, green: 0x4C, blue: 0x4C)),
        ]

        for (percent, expected) in examples {
            XCTAssertEqual(UsageColor.cpuGPU(percent: percent), expected, "Input: \(percent)%")
        }
    }

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
