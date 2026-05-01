import Foundation

struct TelegramStateStore {
    private let directoryURL: URL
    private let fileManager: FileManager
    private let afterTemporaryWrite: () throws -> Void

    init(
        directoryURL: URL = TelegramStateStore.defaultDirectoryURL(),
        fileManager: FileManager = .default,
        afterTemporaryWrite: @escaping () throws -> Void = {}
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.afterTemporaryWrite = afterTemporaryWrite
    }

    func load() throws -> TelegramPersistentState {
        let fileURL = stateFileURL
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return TelegramPersistentState()
        }

        let data = try Data(contentsOf: fileURL)
        let version = try decoder.decode(VersionProbe.self, from: data).version
        guard version == TelegramPersistentState().version else {
            throw TelegramStateStoreError.migrationRequired(version: version)
        }

        return try decoder.decode(TelegramPersistentState.self, from: data)
    }

    func save(_ state: TelegramPersistentState) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let data = try encoder.encode(state)
        let fileURL = stateFileURL
        let temporaryURL = directoryURL.appendingPathComponent(".state-\(UUID().uuidString).tmp")

        defer { try? fileManager.removeItem(at: temporaryURL) }

        try data.write(to: temporaryURL, options: [.atomic])
        try afterTemporaryWrite()

        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(
                fileURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: fileURL)
        }
    }

    private var stateFileURL: URL {
        directoryURL.appendingPathComponent("state.json")
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        JSONDecoder()
    }

    static func defaultDirectoryURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PingIsland/telegram", isDirectory: true)
    }

    private struct VersionProbe: Decodable {
        let version: Int
    }
}

enum TelegramStateStoreError: Error, Equatable {
    case migrationRequired(version: Int)
    case simulatedWriteFailure
}
