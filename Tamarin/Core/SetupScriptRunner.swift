import Foundation

public nonisolated enum SetupScriptError: LocalizedError, Sendable {
    case workingDirectoryUnavailable(String)
    case failed(status: Int32, detail: String)

    public var errorDescription: String? {
        switch self {
        case let .workingDirectoryUnavailable(path):
            return "The setup script working directory is unavailable: \(path)"
        case let .failed(status, detail):
            return "The setup script failed with exit status \(status). \(detail)"
        }
    }
}

/// Runs a repository's setup script in a newly created worktree using a login
/// zsh, matching the environment users expect from their terminal.
public nonisolated struct SetupScriptRunner: Sendable {
    public static let shellURL = URL(fileURLWithPath: "/bin/zsh")

    private let processRunner: ProcessRunner

    public init(processRunner: ProcessRunner = ProcessRunner()) {
        self.processRunner = processRunner
    }

    @discardableResult
    public func run(script: String, in workingDirectory: URL) async throws -> ProcessResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: workingDirectory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw SetupScriptError.workingDirectoryUnavailable(workingDirectory.path)
        }

        let scriptDirectory = FileManager.default.temporaryDirectory
            .appending(path: "Tamarin-Setup", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: scriptDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let scriptURL = scriptDirectory
            .appending(path: "\(UUID().uuidString).zsh", directoryHint: .notDirectory)
        try Data(script.utf8).write(to: scriptURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: scriptURL.path
        )
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let result = try await processRunner.run(
            executableURL: Self.shellURL,
            arguments: ["-l", scriptURL.path],
            currentDirectoryURL: workingDirectory,
            environment: ["TAMARIN_WORKTREE": workingDirectory.path]
        )

        guard result.succeeded else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail: String
            if !stderr.isEmpty {
                detail = stderr
            } else if !stdout.isEmpty {
                detail = stdout
            } else {
                detail = "The shell did not provide an error message."
            }
            throw SetupScriptError.failed(status: result.terminationStatus, detail: detail)
        }

        return result
    }
}
