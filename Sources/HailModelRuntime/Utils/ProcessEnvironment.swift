#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Environment-based configuration shared by the harness endpoints.
/// Named `ProcessEnvironment` to avoid colliding with swift-subprocess's
/// `Environment` in files that import both.
enum ProcessEnvironment {
    /// Reads a duration in seconds from an environment variable, falling back
    /// to `value` when the variable is unset or not an integer. Endpoints call
    /// this once at init and store the result, so the environment is consulted
    /// exactly once per instance — never mid-turn.
    static func timeInterval(from key: String, default value: TimeInterval) -> TimeInterval {
        if let raw = ProcessInfo.processInfo.environment[key], let seconds = Int(raw) {
            return TimeInterval(seconds)
        }
        return value
    }
}
