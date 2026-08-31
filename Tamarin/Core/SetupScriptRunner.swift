import Foundation

public nonisolated enum WorktreeScriptPhase: String, Sendable {
    case setup
    case teardown

    var displayName: String { rawValue }
}

public nonisolated enum SetupScriptError: LocalizedError, Sendable {
    case workingDirectoryUnavailable(String)
    case baseRepositoryUnavailable(String)
    case failed(status: Int32, detail: String)
    case lifecycleFailed(phase: WorktreeScriptPhase, status: Int32, detail: String)

    public var errorDescription: String? {
        switch self {
        case let .workingDirectoryUnavailable(path):
            return "The worktree script directory is unavailable: \(path)"
        case let .baseRepositoryUnavailable(path):
            return "The base repository directory is unavailable: \(path)"
        case let .failed(status, detail):
            return "The setup script failed with exit status \(status). \(detail)"
        case let .lifecycleFailed(phase, status, detail):
            return "The \(phase.displayName) script failed with exit status \(status). \(detail)"
        }
    }
}

/// Runs repository lifecycle scripts in a worktree using an interactive login
/// zsh, matching the environment users expect from their terminal.
public nonisolated struct SetupScriptRunner: Sendable {
    public static let shellURL = URL(fileURLWithPath: "/bin/zsh")

    private let processRunner: ProcessRunner

    public init(processRunner: ProcessRunner = ProcessRunner()) {
        self.processRunner = processRunner
    }

    @discardableResult
    public func run(script: String, in workingDirectory: URL) async throws -> ProcessResult {
        try await runLegacySetup(script: script, in: workingDirectory)
    }

    @discardableResult
    public func run(
        script: String,
        phase: WorktreeScriptPhase,
        baseRepositoryDirectory: URL,
        worktreeDirectory: URL
    ) async throws -> ProcessResult {
        let result = try await runCapturingResult(
            script: script,
            phase: phase,
            baseRepositoryDirectory: baseRepositoryDirectory,
            worktreeDirectory: worktreeDirectory
        )

        guard result.succeeded else {
            throw SetupScriptError.lifecycleFailed(
                phase: phase,
                status: result.terminationStatus,
                detail: Self.errorDetail(from: result)
            )
        }

        return result
    }

    /// Runs a lifecycle script and returns its complete output even when the
    /// script exits unsuccessfully. Process-launch and I/O failures still throw.
    @discardableResult
    public func runCapturingResult(
        script: String,
        phase: WorktreeScriptPhase,
        baseRepositoryDirectory: URL,
        worktreeDirectory: URL,
        standardOutputHandler: (@Sendable (Data) -> Void)? = nil,
        standardErrorHandler: (@Sendable (Data) -> Void)? = nil
    ) async throws -> ProcessResult {
        try validateDirectory(baseRepositoryDirectory, baseRepository: true)
        try validateDirectory(worktreeDirectory, baseRepository: false)

        return try await executeScript(
            script: script,
            phase: phase,
            baseRepositoryDirectory: baseRepositoryDirectory,
            worktreeDirectory: worktreeDirectory,
            standardOutputHandler: standardOutputHandler,
            standardErrorHandler: standardErrorHandler
        )
    }

    private func runLegacySetup(
        script: String,
        in workingDirectory: URL
    ) async throws -> ProcessResult {
        try validateDirectory(workingDirectory, baseRepository: false)

        let result = try await executeScript(
            script: script,
            phase: .setup,
            baseRepositoryDirectory: workingDirectory,
            worktreeDirectory: workingDirectory
        )

        guard result.succeeded else {
            throw SetupScriptError.failed(
                status: result.terminationStatus,
                detail: Self.errorDetail(from: result)
            )
        }

        return result
    }

    private func validateDirectory(_ url: URL, baseRepository: Bool) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            if baseRepository {
                throw SetupScriptError.baseRepositoryUnavailable(url.path)
            }
            throw SetupScriptError.workingDirectoryUnavailable(url.path)
        }
    }

    private func executeScript(
        script: String,
        phase: WorktreeScriptPhase,
        baseRepositoryDirectory: URL,
        worktreeDirectory: URL,
        standardOutputHandler: (@Sendable (Data) -> Void)? = nil,
        standardErrorHandler: (@Sendable (Data) -> Void)? = nil
    ) async throws -> ProcessResult {
        let scriptDirectory = FileManager.default.temporaryDirectory
            .appending(path: "Tamarin-Scripts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: scriptDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let scriptURL = scriptDirectory
            .appending(
                path: "\(phase.rawValue)-\(UUID().uuidString).zsh",
                directoryHint: .notDirectory
            )
        try Data(script.utf8).write(to: scriptURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: scriptURL.path
        )
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let result = try await processRunner.run(
            executableURL: Self.shellURL,
            // `-l` reads login configuration such as `.zprofile`; `-i` also
            // reads `.zshrc`, where nvm, Homebrew, asdf, and similar tools are
            // commonly added to PATH. A GUI app otherwise inherits only the
            // minimal launch-services environment.
            arguments: ["-l", "-i", scriptURL.path],
            currentDirectoryURL: worktreeDirectory,
            environment: [
                "TAMARIN_REPO_DIR": baseRepositoryDirectory.path,
                "TAMARIN_WORKTREE_DIR": worktreeDirectory.path,
                // Keep the original setup variable working for repositories
                // configured by earlier Tamarin versions.
                "TAMARIN_REPO": baseRepositoryDirectory.path,
                "TAMARIN_WORKTREE": worktreeDirectory.path,
            ],
            standardOutputHandler: standardOutputHandler,
            standardErrorHandler: standardErrorHandler
        )
        return result
    }

    private static func errorDetail(from result: ProcessResult) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return stdout.isEmpty ? "The shell did not provide an error message." : stdout
    }
}
