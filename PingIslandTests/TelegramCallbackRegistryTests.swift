import XCTest
@testable import Ping_Island

final class TelegramCallbackRegistryTests: XCTestCase {
    func testStoresAndResolvesCallbackByToken() async throws {
        let stateStore = InMemoryTelegramStateStore()
        let registry = TelegramCallbackRegistry(stateStore: stateStore)
        let resolution = makeResolution(action: .allowOnce)

        try await registry.upsert(["token-1": resolution])

        let storedResolution = try await registry.resolve(token: "token-1")
        XCTAssertEqual(storedResolution, resolution)
    }

    func testUpsertMergesWithExistingCallbacksAndPreservesMessages() async throws {
        let existing = makeResolution(action: .deny)
        let messageEntry = TelegramPersistentState.MessageEntry(
            chatId: 123,
            messageId: 456,
            sentAt: Date(timeIntervalSince1970: 1_775_000_010)
        )
        let stateStore = InMemoryTelegramStateStore(TelegramPersistentState(
            messages: [
                InterventionKey.make(sessionId: "session-1", interventionId: "tool-use-1"): messageEntry
            ],
            callbacks: ["existing-token": existing]
        ))
        let registry = TelegramCallbackRegistry(stateStore: stateStore)
        let inserted = makeResolution(action: .allowSession)

        try await registry.upsert(["new-token": inserted])

        let state = try stateStore.load()
        XCTAssertEqual(state.callbacks["existing-token"], existing)
        XCTAssertEqual(state.callbacks["new-token"], inserted)
        XCTAssertEqual(
            state.messages[InterventionKey.make(sessionId: "session-1", interventionId: "tool-use-1")],
            messageEntry
        )
    }

    func testRemoveDeletesOnlyRequestedTokens() async throws {
        let keep = makeResolution(action: .allowOnce)
        let remove = makeResolution(action: .deny)
        let stateStore = InMemoryTelegramStateStore(TelegramPersistentState(callbacks: [
            "keep-token": keep,
            "remove-token": remove
        ]))
        let registry = TelegramCallbackRegistry(stateStore: stateStore)

        try await registry.remove(tokens: ["remove-token"])

        let keptResolution = try await registry.resolve(token: "keep-token")
        let removedResolution = try await registry.resolve(token: "remove-token")
        XCTAssertEqual(keptResolution, keep)
        XCTAssertNil(removedResolution)
    }

    private func makeResolution(
        action: TelegramPersistentState.CallbackResolution.Action
    ) -> TelegramPersistentState.CallbackResolution {
        TelegramPersistentState.CallbackResolution(
            sessionId: "session-1",
            interventionId: "tool-use-1",
            action: action,
            issuedAt: Date(timeIntervalSince1970: 1_775_000_000)
        )
    }
}

final class InMemoryTelegramStateStore: TelegramStateStoring {
    private var state: TelegramPersistentState

    init(_ state: TelegramPersistentState = TelegramPersistentState()) {
        self.state = state
    }

    func load() throws -> TelegramPersistentState {
        state
    }

    func save(_ state: TelegramPersistentState) throws {
        self.state = state
    }
}
