import HailCore
import Testing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@Suite("Tool registry request stability")
struct ToolRegistryTests {
    @Test("schemas are sorted independently of registration order")
    func schemasHaveStableOrder() async {
        let registry = ToolRegistry()
        await registry.register(NowTool())
        await registry.register(FileTool(projectRoot: URL(fileURLWithPath: "/tmp")))

        let names = await registry.schemas().map(\.name)

        #expect(names == ["file", "now"])
    }
}
