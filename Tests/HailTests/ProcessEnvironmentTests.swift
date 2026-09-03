import Testing

@testable import HailModelRuntime

@Suite("Process environment")
struct ProcessEnvironmentTests {
    @Test("only an unset duration selects its default")
    func unsetDurationUsesDefault() throws {
        let value = try ProcessEnvironment.timeInterval(
            nil,
            key: "TEST_TIMEOUT",
            default: 30
        )

        #expect(value == 30)
    }

    @Test(
        "invalid explicit durations throw",
        arguments: ["", "abc", "0", "-1", "nan", "inf"]
    )
    func invalidDurationThrows(raw: String) {
        #expect(
            throws: ModelRouterError.invalidEnvironmentValue(
                key: "TEST_TIMEOUT",
                value: raw
            )
        ) {
            try ProcessEnvironment.timeInterval(
                raw,
                key: "TEST_TIMEOUT",
                default: 30
            )
        }
    }

    @Test("positive explicit durations are preserved")
    func validDurationIsPreserved() throws {
        let value = try ProcessEnvironment.timeInterval(
            "2.5",
            key: "TEST_TIMEOUT",
            default: 30
        )

        #expect(value == 2.5)
    }
}
