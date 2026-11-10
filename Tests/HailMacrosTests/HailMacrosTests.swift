import HailMacros
import SwiftSyntaxMacros
import Testing

struct HailMacrosTests {
    @Test
    func toolMacroIsRegistered() {
        let macros: [String: any Macro.Type] = [
            "Tool": ToolMacro.self,
            "Command": CommandMacro.self,
        ]
        #expect(macros.count == 2)
    }
}
