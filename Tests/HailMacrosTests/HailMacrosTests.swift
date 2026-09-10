import SwiftSyntaxMacros
import Testing
import HailMacros

struct HailMacrosTests {
    @Test
    func toolMacroIsRegistered() {
        let macros: [String: Macro.Type] = [
            "Tool": ToolMacro.self,
            "Command": CommandMacro.self
        ]
        #expect(macros.count == 2)
    }
}
