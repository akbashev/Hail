#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Environment-based configuration shared by the harness endpoints.
/// Named `ProcessEnvironment` to avoid colliding with swift-subprocess's
/// `Environment` in files that import both.
enum ProcessEnvironment {
    static func timeInterval(
        override: TimeInterval?,
        from key: String,
        default value: TimeInterval
    ) throws(ModelRouterError) -> TimeInterval {
        if let override {
            guard override.isFinite, override > 0 else {
                throw .invalidEnvironmentValue(key: "explicit \(key) override", value: "\(override)")
            }
            return override
        }
        return try timeInterval(from: key, default: value)
    }

    /// Reads a positive duration in seconds. Absence selects the documented
    /// default; an explicitly malformed or non-positive value is invalid
    /// configuration and never masquerades as absence.
    static func timeInterval(
        from key: String,
        default value: TimeInterval
    ) throws(ModelRouterError) -> TimeInterval {
        try timeInterval(
            ProcessInfo.processInfo.environment[key],
            key: key,
            default: value
        )
    }

    /// Pure parser used by the process boundary and its tests.
    static func timeInterval(
        _ raw: String?,
        key: String,
        default value: TimeInterval
    ) throws(ModelRouterError) -> TimeInterval {
        guard let raw else {
            return value
        }
        guard let seconds = TimeInterval(raw), seconds.isFinite, seconds > 0 else {
            throw .invalidEnvironmentValue(key: key, value: raw)
        }
        return seconds
    }
}
