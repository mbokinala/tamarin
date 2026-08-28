import Foundation

nonisolated struct RepositoryStore {
    private struct Payload: Codable {
        var version = 1
        var repositories: [RepositoryRecord]
    }

    let fileURL: URL

    init(fileManager: FileManager = .default) {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        fileURL = applicationSupport
            .appending(path: "Tamarin", directoryHint: .isDirectory)
            .appending(path: "repositories-v1.json", directoryHint: .notDirectory)
    }

    func load(fileManager: FileManager = .default) throws -> [RepositoryRecord] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(Payload.self, from: data).repositories
    }

    func save(
        _ repositories: [RepositoryRecord],
        fileManager: FileManager = .default
    ) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Payload(repositories: repositories))
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}
