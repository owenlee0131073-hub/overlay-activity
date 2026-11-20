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
