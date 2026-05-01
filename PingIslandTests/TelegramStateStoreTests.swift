import XCTest
@testable import Ping_Island

final class TelegramStateStoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testLoadWhenFileMissingReturnsDefaults() throws {
        let store = TelegramStateStore(directoryURL: makeTemporaryDirectory())

        XCTAssertEqual(try store.load(), TelegramPersistentState())
    }

    func testSaveThenLoadRoundTrips() throws {
        let store = TelegramStateStore(directoryURL: makeTemporaryDirectory())
        let state = makeState()

        try store.save(state)

        XCTAssertEqual(try store.load(), state)
    }

    func testSaveAtomicallyPreservesExistingFileWhenTempWriteFaults() throws {
        let directory = makeTemporaryDirectory()
        let store = TelegramStateStore(directoryURL: directory)
        let original = makeState(offset: 10)
        let replacement = makeState(offset: 20)

        try store.save(original)

        let failingStore = TelegramStateStore(
            directoryURL: directory,
            afterTemporaryWrite: {
                throw TelegramStateStoreError.simulatedWriteFailure
            }
        )

        XCTAssertThrowsError(try failingStore.save(replacement)) { error in
            XCTAssertEqual(error as? TelegramStateStoreError, .simulatedWriteFailure)
        }
        XCTAssertEqual(try store.load(), original)
    }

    func testLoadUnknownVersionThrowsMigrationRequired() throws {
        let directory = makeTemporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("state.json")
        try Data(#"{"version":999,"auth":{},"poller":{},"messages":{},"callbacks":{}}"#.utf8)
            .write(to: fileURL)

        let store = TelegramStateStore(directoryURL: directory)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? TelegramStateStoreError, .migrationRequired(version: 999))
        }
    }

    private func makeState(offset: Int64 = 42) -> TelegramPersistentState {
        TelegramPersistentState(
            auth: .init(chatId: 123),
            poller: .init(offset: offset),
            messages: [
                "session-1|tool-1": .init(
                    chatId: 123,
                    messageId: 456,
                    sentAt: Date(timeIntervalSince1970: 1_775_000_000)
                )
            ],
            callbacks: [
                "callback-token": .init(
                    sessionId: "session-1",
                    interventionId: "tool-1",
                    action: .answerOption(questionId: "question-1", optionTitle: "Allow"),
                    issuedAt: Date(timeIntervalSince1970: 1_775_000_010)
                )
            ]
        )
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TelegramStateStoreTests-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
