import XCTest
@testable import Ping_Island

final class TelegramMessageRegistryTests: XCTestCase {
    func testStoresMessageEntryByCompositeInterventionKey() async throws {
        let stateStore = InMemoryTelegramStateStore()
        let registry = TelegramMessageRegistry(stateStore: stateStore)
        let entry = TelegramPersistentState.MessageEntry(
            chatId: 123,
            messageId: 456,
            sentAt: Date(timeIntervalSince1970: 1_775_000_000)
        )

        try await registry.upsert(
            entry,
            sessionId: "session-1",
            interventionId: "tool-use-1"
        )

        let storedEntry = try await registry.entry(sessionId: "session-1", interventionId: "tool-use-1")
        XCTAssertEqual(storedEntry, entry)
        XCTAssertEqual(
            try stateStore.load().messages[InterventionKey.make(sessionId: "session-1", interventionId: "tool-use-1")],
            entry
        )
    }

    func testUpsertPreservesOtherPersistentState() async throws {
        let existingResolution = TelegramPersistentState.CallbackResolution(
            sessionId: "session-0",
            interventionId: "intervention-0",
            action: .deny,
            issuedAt: Date(timeIntervalSince1970: 1_775_000_001)
        )
        let stateStore = InMemoryTelegramStateStore(TelegramPersistentState(
            auth: .init(chatId: 999),
            poller: .init(offset: 42),
            callbacks: ["callback-token": existingResolution]
        ))
        let registry = TelegramMessageRegistry(stateStore: stateStore)

        try await registry.upsert(
            .init(chatId: 123, messageId: 456, sentAt: Date(timeIntervalSince1970: 1_775_000_000)),
            sessionId: "session-1",
            interventionId: "tool-use-1"
        )

        let state = try stateStore.load()
        XCTAssertEqual(state.auth.chatId, 999)
        XCTAssertEqual(state.poller.offset, 42)
        XCTAssertEqual(state.callbacks["callback-token"], existingResolution)
    }

    func testRemoveDeletesOnlyMatchingCompositeKey() async throws {
        let keep = TelegramPersistentState.MessageEntry(
            chatId: 123,
            messageId: 456,
            sentAt: Date(timeIntervalSince1970: 1_775_000_000)
        )
        let remove = TelegramPersistentState.MessageEntry(
            chatId: 123,
            messageId: 789,
            sentAt: Date(timeIntervalSince1970: 1_775_000_010)
        )
        let stateStore = InMemoryTelegramStateStore(TelegramPersistentState(messages: [
            InterventionKey.make(sessionId: "session-1", interventionId: "tool-use-1"): remove,
            InterventionKey.make(sessionId: "session-2", interventionId: "tool-use-1"): keep
        ]))
        let registry = TelegramMessageRegistry(stateStore: stateStore)

        try await registry.remove(sessionId: "session-1", interventionId: "tool-use-1")

        let removedEntry = try await registry.entry(sessionId: "session-1", interventionId: "tool-use-1")
        let keptEntry = try await registry.entry(sessionId: "session-2", interventionId: "tool-use-1")
        XCTAssertNil(removedEntry)
        XCTAssertEqual(keptEntry, keep)
    }
}
