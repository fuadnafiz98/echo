import Testing
@testable import echo

@MainActor
@Suite("Empty-take menu error")
struct EmptyTakeErrorTests {
    @Test func clearEmptyTakeErrorLeavesOtherErrors() {
        let state = AppState()
        state.errorMessage = "Microphone isn’t available."
        state.clearEmptyTakeError()
        #expect(state.errorMessage == "Microphone isn’t available.")

        state.presentEmptyTakeError()
        #expect(state.errorMessage == AppState.emptyTakeError)
        state.clearEmptyTakeError()
        #expect(state.errorMessage == nil)
    }

    @Test func deliverEmptyStringUsesEmptyTakeCopy() throws {
        let source = try AppSource.load("EchoCoordinator.swift")
        let deliver = try #require(AppSource.method(source, named: "deliver"))
        #expect(deliver.contains("presentEmptyTakeError()"))
        #expect(!deliver.contains(AppState.emptyTakeError))
    }
}
