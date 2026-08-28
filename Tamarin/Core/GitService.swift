import Foundation

public nonisolated enum GitServiceError: LocalizedError, Sendable {
    case pathDoesNotExist(String)
    case pathIsNotDirectory(String)
    case notRepository(path: String, detail: String)
    case commandFailed(operation: String, status: Int32?, detail: String)
    case invalidOutput(operation: String)
    case targetAlreadyExists(String)
    case branchAlreadyCheckedOut(branch: String, path: String)
    case cannotRemovePrimaryWorktree(String)
    case worktreeNotFound(String)
    case worktreeRemovalRequiresForce(path: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case let .pathDoesNotExist(path):
            return "The folder does not exist: \(path)"
        case let .pathIsNotDirectory(path):
            return "The selected path is not a folder: \(path)"
        case let .notRepository(path, detail):
            return "The selected folder is not a Git repository: \(path). \(detail)"
        case let .commandFailed(operation, status, detail):
            let statusText = status.map { " (exit status \($0))" } ?? ""
            return "Could not \(operation)\(statusText). \(detail)"
        case let .invalidOutput(operation):
            return "Git returned unexpected output while trying to \(operation)."
        case let .targetAlreadyExists(path):
            return "A file or folder already exists at the new worktree location: \(path)"
        case let .branchAlreadyCheckedOut(branch, path):
            return "The branch “\(branch)” is already checked out at \(path)."
        case let .cannotRemovePrimaryWorktree(path):
            return "The primary repository worktree cannot be removed: \(path)"
        case let .worktreeNotFound(path):
            return "Git does not have a registered worktree at \(path)."
        case let .worktreeRemovalRequiresForce(path, _):
            return "The worktree at \(path) can only be removed with force."
        }
    }
}

/// Git operations used by the repository and worktree UI.
///
/// Every invocation uses `/usr/bin/git` with an explicit argument array. No user
/// value is interpreted by a shell.
public nonisolated struct GitService: Sendable {
    public static let gitURL = URL(fileURLWithPath: "/usr/bin/git")

    private let processRunner: ProcessRunner

    public init(processRunner: ProcessRunner = ProcessRunner()) {
        self.processRunner = processRunner
    }

    /// Verifies that `url` is inside a non-bare Git worktree and returns Git's
    /// canonical top-level folder, resolving `.`/`..` and symbolic links.
    public func validateRepository(at url: URL) async throws -> URL {
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            throw GitServiceError.pathDoesNotExist(candidate.path)
        }
        guard isDirectory.boolValue else {
            throw GitServiceError.pathIsNotDirectory(candidate.path)
        }

        let result: ProcessResult
        do {
            result = try await processRunner.run(
                executableURL: Self.gitURL,
                arguments: ["-C", candidate.path, "rev-parse", "--is-inside-work-tree", "--show-toplevel"]
            )
        } catch {
            throw GitServiceError.commandFailed(
                operation: "inspect the repository",
                status: nil,
                detail: error.localizedDescription
            )
        }

        guard result.succeeded else {
            throw GitServiceError.notRepository(
                path: candidate.path,
                detail: Self.errorDetail(from: result)
            )
        }

        let lines = result.stdout
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)

        guard lines.count >= 2,
              lines[lines.count - 2].trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        else {
            throw GitServiceError.notRepository(
                path: candidate.path,
                detail: "Only non-bare Git worktrees can be managed."
            )
        }

        let rootPath = lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rootPath.isEmpty else {
            throw GitServiceError.invalidOutput(operation: "find the repository root")
        }

        let root: URL
        if rootPath.hasPrefix("/") {
            root = URL(fileURLWithPath: rootPath, isDirectory: true)
        } else {
            root = URL(fileURLWithPath: rootPath, isDirectory: true, relativeTo: candidate)
        }
        return root.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Validates a selected source folder and creates its persistence record.
    public func makeRepository(
        from sourceURL: URL,
        worktreeRoot: URL? = nil,
        setupScript: String? = nil,
        id: UUID = UUID()
    ) async throws -> RepositoryRecord {
        let canonicalRoot = try await validateRepository(at: sourceURL)
        let canonicalWorktreeRoot = worktreeRoot?
            .standardizedFileURL
            .resolvingSymlinksInPath()

        return RepositoryRecord(
            id: id,
            name: canonicalRoot.lastPathComponent,
            repositoryURL: canonicalRoot,
            worktreeRootURL: canonicalWorktreeRoot,
            setupScript: setupScript
        )
    }

    /// Alias that reads naturally at an "Add repository" call site.
    public func addRepository(
        at sourceURL: URL,
        worktreeRoot: URL? = nil,
        setupScript: String? = nil,
        id: UUID = UUID()
    ) async throws -> RepositoryRecord {
        try await makeRepository(
            from: sourceURL,
            worktreeRoot: worktreeRoot,
            setupScript: setupScript,
            id: id
        )
    }

    public func listWorktrees(in repository: RepositoryRecord) async throws -> [WorktreeInfo] {
        let result = try await runGit(
            ["worktree", "list", "--porcelain", "-z"],
            in: repository,
            operation: "list worktrees"
        )
        let worktrees = Self.parseWorktreePorcelain(result.stdoutData)
        guard !worktrees.isEmpty else {
            throw GitServiceError.invalidOutput(operation: "list worktrees")
        }
        return worktrees
    }

    public func listBranches(
        in repository: RepositoryRecord,
        worktrees suppliedWorktrees: [WorktreeInfo]? = nil
    ) async throws -> [GitBranch] {
        async let refsResult = runGit(
            [
                "for-each-ref",
                "--format=%(refname)%09%(symref)",
                "refs/heads",
                "refs/remotes"
            ],
            in: repository,
            operation: "list branches"
        )
        async let remoteResult = runGit(
            ["remote"],
            in: repository,
            operation: "list remotes"
        )

        let (refs, remotesOutput) = try await (refsResult, remoteResult)
        let worktrees: [WorktreeInfo]
        if let suppliedWorktrees {
            worktrees = suppliedWorktrees
        } else {
            worktrees = try await listWorktrees(in: repository)
        }
        let remoteNames = remotesOutput.stdout
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .sorted { $0.count > $1.count }

        let checkoutByBranch = Dictionary(
            worktrees.compactMap { worktree -> (String, String)? in
                guard let branch = worktree.branch else { return nil }
                return (branch, worktree.path)
            },
            uniquingKeysWith: { first, _ in first }
        )

        var branches: [GitBranch] = []
        for line in refs.stdout.split(whereSeparator: \Character.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawReference = fields.first else { continue }
            let reference = String(rawReference)
            let symbolicTarget = fields.count == 2 ? String(fields[1]) : ""

            if reference.hasPrefix("refs/heads/") {
                let name = String(reference.dropFirst("refs/heads/".count))
                guard !name.isEmpty else { continue }
                let path = checkoutByBranch[name]
                branches.append(
                    GitBranch(
                        kind: .local,
                        reference: reference,
                        displayName: name,
                        localBranchName: name,
                        isCheckedOut: path != nil,
                        checkoutPath: path
                    )
                )
            } else if reference.hasPrefix("refs/remotes/"), symbolicTarget.isEmpty {
                let displayName = String(reference.dropFirst("refs/remotes/".count))
                guard !displayName.isEmpty else { continue }
                let localName = Self.localCandidate(forRemoteDisplayName: displayName, remotes: remoteNames)
                let path = checkoutByBranch[localName]
                branches.append(
                    GitBranch(
                        kind: .remote,
                        reference: reference,
                        displayName: displayName,
                        localBranchName: localName,
                        isCheckedOut: path != nil,
                        checkoutPath: path
                    )
                )
            }
        }

        return branches.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .local }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// Creates a worktree for an existing local branch, or creates a local branch
    /// that tracks the selected remote branch.
    public func createWorktree(
        repository: RepositoryRecord,
        branch: GitBranch,
        at targetURL: URL
    ) async throws -> WorktreeInfo {
        if branch.isCheckedOut, let checkoutPath = branch.checkoutPath {
            throw GitServiceError.branchAlreadyCheckedOut(
                branch: branch.localBranchName,
                path: checkoutPath
            )
        }

        let target = targetURL.standardizedFileURL
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw GitServiceError.targetAlreadyExists(target.path)
        }

        do {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw GitServiceError.commandFailed(
                operation: "create the worktree parent folder",
                status: nil,
                detail: error.localizedDescription
            )
        }

        var arguments = ["worktree", "add"]
        if branch.kind == .local {
            // Passing the fully-qualified refs/heads/... name here makes Git
            // treat it as a commit-ish and create a detached worktree. The short
            // local name preserves the branch checkout.
            arguments += ["--", target.path, branch.localBranchName]
        } else if try await localBranchExists(branch.localBranchName, in: repository) {
            arguments += ["--", target.path, branch.localBranchName]
        } else {
            arguments += ["--track", "-b", branch.localBranchName, "--", target.path, branch.reference]
        }

        _ = try await runGit(arguments, in: repository, operation: "create the worktree")

        let normalizedTarget = Self.normalizedPath(target)
        guard let created = try await listWorktrees(in: repository).first(where: {
            Self.normalizedPath($0.url) == normalizedTarget
        }) else {
            throw GitServiceError.invalidOutput(operation: "find the newly created worktree")
        }
        return created
    }

    /// Removes a registered linked worktree. Without `force`, Git protects
    /// dirty worktrees and reports that the caller must explicitly retry.
    public func removeWorktree(
        repository: RepositoryRecord,
        path worktreeURL: URL,
        force: Bool = false
    ) async throws {
        let normalizedRequestedPath = Self.normalizedPath(worktreeURL)
        let worktrees = try await listWorktrees(in: repository)
        guard let worktree = worktrees.first(where: {
            Self.normalizedPath($0.url) == normalizedRequestedPath
        }) else {
            throw GitServiceError.worktreeNotFound(worktreeURL.path)
        }

        guard !worktree.isPrimary else {
            throw GitServiceError.cannotRemovePrimaryWorktree(worktree.path)
        }

        var arguments = ["worktree", "remove"]
        if force {
            arguments.append("--force")
        }
        arguments += ["--", worktree.path]

        do {
            _ = try await runGit(
                arguments,
                in: repository,
                operation: "remove the worktree"
            )
        } catch let error as GitServiceError {
            guard !force,
                  case let .commandFailed(_, _, detail) = error,
                  Self.removalErrorRequiresForce(detail)
            else {
                throw error
            }
            throw GitServiceError.worktreeRemovalRequiresForce(
                path: worktree.path,
                detail: detail
            )
        }
    }

    private func localBranchExists(
        _ branchName: String,
        in repository: RepositoryRecord
    ) async throws -> Bool {
        let result: ProcessResult
        do {
            result = try await processRunner.run(
                executableURL: Self.gitURL,
                arguments: [
                    "-C",
                    repository.repositoryURL.path,
                    "show-ref",
                    "--verify",
                    "--quiet",
                    "refs/heads/\(branchName)"
                ]
            )
        } catch {
            throw GitServiceError.commandFailed(
                operation: "check the local branch",
                status: nil,
                detail: error.localizedDescription
            )
        }

        switch result.terminationStatus {
        case 0: return true
        case 1: return false
        default:
            throw GitServiceError.commandFailed(
                operation: "check the local branch",
                status: result.terminationStatus,
                detail: Self.errorDetail(from: result)
            )
        }
    }

    private func runGit(
        _ arguments: [String],
        in repository: RepositoryRecord,
        operation: String
    ) async throws -> ProcessResult {
        let result: ProcessResult
        do {
            result = try await processRunner.run(
                executableURL: Self.gitURL,
                arguments: ["-C", repository.repositoryURL.path] + arguments,
                environment: ["GIT_TERMINAL_PROMPT": "0"]
            )
        } catch {
            throw GitServiceError.commandFailed(
                operation: operation,
                status: nil,
                detail: error.localizedDescription
            )
        }

        guard result.succeeded else {
            throw GitServiceError.commandFailed(
                operation: operation,
                status: result.terminationStatus,
                detail: Self.errorDetail(from: result)
            )
        }
        return result
    }

    static func parseWorktreePorcelain(_ data: Data) -> [WorktreeInfo] {
        struct Builder {
            var path: String?
            var branch: String?
            var head: String?
            var detached = false
            var locked = false
            var lockReason: String?
            var prunable = false
            var pruneReason: String?
        }

        var records: [Builder] = []
        var current = Builder()

        func appendCurrentIfNeeded() {
            guard current.path != nil else { return }
            records.append(current)
            current = Builder()
        }

        for bytes in data.split(separator: 0, omittingEmptySubsequences: false) {
            guard !bytes.isEmpty else {
                appendCurrentIfNeeded()
                continue
            }

            let field = String(decoding: bytes, as: UTF8.self)
            if field.hasPrefix("worktree ") {
                appendCurrentIfNeeded()
                current.path = String(field.dropFirst("worktree ".count))
            } else if field.hasPrefix("HEAD ") {
                current.head = String(field.dropFirst("HEAD ".count))
            } else if field.hasPrefix("branch ") {
                let reference = String(field.dropFirst("branch ".count))
                current.branch = reference.hasPrefix("refs/heads/")
                    ? String(reference.dropFirst("refs/heads/".count))
                    : reference
            } else if field == "detached" || field == "bare" {
                current.detached = true
            } else if field == "locked" {
                current.locked = true
            } else if field.hasPrefix("locked ") {
                current.locked = true
                current.lockReason = String(field.dropFirst("locked ".count))
            } else if field == "prunable" {
                current.prunable = true
            } else if field.hasPrefix("prunable ") {
                current.prunable = true
                current.pruneReason = String(field.dropFirst("prunable ".count))
            }
        }
        appendCurrentIfNeeded()

        return records.enumerated().compactMap { index, record in
            guard let path = record.path else { return nil }
            return WorktreeInfo(
                path: path,
                branch: record.branch,
                head: record.head,
                isDetached: record.detached,
                isPrimary: index == 0,
                isLocked: record.locked,
                lockReason: record.lockReason,
                isPrunable: record.prunable,
                pruneReason: record.pruneReason
            )
        }
    }

    private static func localCandidate(forRemoteDisplayName name: String, remotes: [String]) -> String {
        for remote in remotes where name.hasPrefix(remote + "/") {
            let candidate = String(name.dropFirst(remote.count + 1))
            if !candidate.isEmpty { return candidate }
        }
        return name.split(separator: "/", maxSplits: 1).last.map(String.init) ?? name
    }

    private static func errorDetail(from result: ProcessResult) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return stdout.isEmpty ? "Git did not provide an error message." : stdout
    }

    private static func removalErrorRequiresForce(_ detail: String) -> Bool {
        let lowercaseDetail = detail.lowercased()
        return lowercaseDetail.contains("--force")
            || lowercaseDetail.contains("-f -f")
            || lowercaseDetail.contains("working trees containing submodules")
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
