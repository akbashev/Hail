import Hail
import Testing

@Suite("ModelEndpointError")
struct ModelEndpointErrorTests {
    @Test("formats Codex api errors using the last ERROR line")
    func formatsCodexAPIErrorsUsingLastErrorLine() {
        let message = HailErrorFormatter.userFacingMessage(
            ModelEndpointError.requestFailed(
                """
                OpenAI Codex v0.139.0
                --------
                prompt transcript
                ERROR: First failure line.
                ERROR: You've hit your usage limit. Try again at 6:16 PM.
                """
            )
        )

        #expect(message == "You've hit your usage limit. Try again at 6:16 PM.")
    }
}
