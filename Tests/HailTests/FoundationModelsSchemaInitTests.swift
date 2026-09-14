#if canImport(FoundationModels)
    import FoundationModels
    import Testing

    /// Probe: does Apple's GenerationSchema init reject a referenceTo name in
    /// "#/$defs/Name" JSON-pointer form when the dependency is registered
    /// under the bare "Name"? (The AnyLanguageModel bridge produces exactly
    /// this mismatch when converting tool parameter schemas.)
    @Suite("FoundationModels schema init probe")
    struct FoundationModelsSchemaInitTests {
        @Test("reference name forms accepted by GenerationSchema init")
        func referenceForms() {
            let bareEnum: DynamicGenerationSchema = .init(
                name: "ProbeAction", description: nil, anyOf: ["deliverPreparedMessage", "performTask"]
            )
            func root(refName: String) -> DynamicGenerationSchema {
                .init(
                    name: "probe_input",
                    description: nil,
                    properties: [
                        .init(
                            name: "action", description: nil,
                            schema: .init(referenceTo: refName),
                            isOptional: false
                        )
                    ]
                )
            }
            do {
                _ = try GenerationSchema(root: root(refName: "#/$defs/ProbeAction"), dependencies: [bareEnum])
                print("PROBE FM INIT: pointer-form ref ACCEPTED")
            } catch {
                print("PROBE FM INIT: pointer-form ref THROWS:", String(describing: error))
            }
            do {
                _ = try GenerationSchema(root: root(refName: "ProbeAction"), dependencies: [bareEnum])
                print("PROBE FM INIT: bare ref ACCEPTED")
            } catch {
                print("PROBE FM INIT: bare ref THROWS:", String(describing: error))
            }
        }
    }
#endif
