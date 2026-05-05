import Foundation

public enum Angle: Sendable, Equatable, Hashable {
    case radians(Double)
    case degrees(Double)

    public var radians: Double {
        switch self {
        case .radians(let v): return v
        case .degrees(let v): return v * .pi / 180.0
        }
    }

    public var degrees: Double {
        switch self {
        case .radians(let v): return v * 180.0 / .pi
        case .degrees(let v): return v
        }
    }
}

public enum Length: Sendable, Equatable, Hashable {
    case meters(Double)
    case millimeters(Double)

    public var meters: Double {
        switch self {
        case .meters(let v): return v
        case .millimeters(let v): return v / 1000.0
        }
    }

    public var millimeters: Double {
        switch self {
        case .meters(let v): return v * 1000.0
        case .millimeters(let v): return v
        }
    }
}
