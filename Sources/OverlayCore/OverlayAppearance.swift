public struct UsageColor: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    private static let low = UsageColor(red: 0x77, green: 0xCA, blue: 0x9B)
    private static let mid = UsageColor(red: 0xCB, green: 0xC0, blue: 0x6C)
    private static let high = UsageColor(red: 0xDC, green: 0x4C, blue: 0x4C)

    public static func cpuGPU(percent: Int) -> Self {
        let clamped = min(100, max(0, percent))
        let lowerHalf = clamped < 50
        let start = lowerHalf ? low : mid
        let end = lowerHalf ? mid : high
        let step = lowerHalf ? clamped : clamped - 50

        func interpolate(_ from: UInt8, _ to: UInt8) -> UInt8 {
            UInt8(Int(from) + step * (Int(to) - Int(from)) / 50)
        }

        return Self(
            red: interpolate(start.red, end.red),
            green: interpolate(start.green, end.green),
            blue: interpolate(start.blue, end.blue)
        )
    }
}

public enum UsageLevel: Equatable, Sendable {
    case normal, high, critical

    public init(percent: Int?) {
        switch percent {
        case let value? where value >= 90:
            self = .critical
        case let value? where value >= 75:
            self = .high
        default:
            self = .normal
        }
    }
}

public enum BackgroundTransparency: Int, CaseIterable, Sendable {
    case opaque = 0
    case quarter = 25
    case half = 50
    case threeQuarters = 75
    case clear = 100

    public static let defaultValue: Self = .quarter

    public var opacity: Double { 1 - Double(rawValue) / 100 }

    public init(savedPercent: Int?) {
        self = savedPercent.flatMap(Self.init(rawValue:)) ?? .defaultValue
    }
}
