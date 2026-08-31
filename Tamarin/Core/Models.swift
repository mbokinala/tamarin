import Foundation

/// A repository managed by Tamarin.
///
/// Paths are stored as strings so records remain straightforward to persist with
/// `Codable`. Use the URL convenience properties when interacting with the file
/// system.
public nonisolated struct RepositoryRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var worktreeRoot: String?
    /// Legacy storage used by releases before repository lifecycle scripts
    /// moved to `.tamarin/config.toml`. New values are not persisted here.
    public var setupScript: String?

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        worktreeRoot: String? = nil,
        setupScript: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.worktreeRoot = worktreeRoot
        self.setupScript = setupScript
    }

    public init(
        id: UUID = UUID(),
        name: String,
        repositoryURL: URL,
        worktreeRootURL: URL? = nil,
        setupScript: String? = nil
    ) {
        self.init(
            id: id,
            name: name,
            path: repositoryURL.path,
            worktreeRoot: worktreeRootURL?.path,
            setupScript: setupScript
        )
    }

    public var repositoryURL: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    public var worktreeRootURL: URL? {
        worktreeRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}

/// Scripts shared by every Tamarin worktree for a repository.
///
/// The configuration is stored in `.tamarin/config.toml` in the repository's
/// primary checkout so it can be versioned with the project when desired.
public nonisolated struct RepositoryLifecycleConfiguration: Equatable, Sendable {
    public var setupScript: String?
    public var teardownScript: String?

    public init(setupScript: String? = nil, teardownScript: String? = nil) {
        self.setupScript = Self.nonEmpty(setupScript)
        self.teardownScript = Self.nonEmpty(teardownScript)
    }

    private static func nonEmpty(_ script: String?) -> String? {
        guard let script,
              !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return script
    }
}

/// A branch that can be selected when creating a worktree.
public nonisolated struct GitBranch: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case local
        case remote
    }

    public var kind: Kind
    /// The fully qualified Git ref, such as `refs/heads/main`.
    public var reference: String
    /// The concise name shown in the branch picker.
    public var displayName: String
    /// The local branch to check out or create for this selection.
    public var localBranchName: String
    public var isCheckedOut: Bool
    public var checkoutPath: String?

    public init(
        kind: Kind,
        reference: String,
        displayName: String,
        localBranchName: String,
        isCheckedOut: Bool = false,
        checkoutPath: String? = nil
    ) {
        self.kind = kind
        self.reference = reference
        self.displayName = displayName
        self.localBranchName = localBranchName
        self.isCheckedOut = isCheckedOut
        self.checkoutPath = checkoutPath
    }

    public var id: String { reference }
    public var isLocal: Bool { kind == .local }
    public var isRemote: Bool { kind == .remote }

    // Short aliases make the model pleasant to use in compact picker views.
    public var ref: String { reference }
    public var display: String { displayName }
    public var localCandidate: String { localBranchName }
    public var checkedOutPath: String? { checkoutPath }
    public var checkoutURL: URL? {
        checkoutPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}

/// One entry returned by `git worktree list --porcelain`.
public nonisolated struct WorktreeInfo: Identifiable, Codable, Hashable, Sendable {
    public var path: String
    /// The short local branch name, or `nil` for a detached/bare worktree.
    public var branch: String?
    public var head: String?
    public var isDetached: Bool
    public var isPrimary: Bool
    public var isLocked: Bool
    public var lockReason: String?
    public var isPrunable: Bool
    public var pruneReason: String?

    public init(
        path: String,
        branch: String? = nil,
        head: String? = nil,
        isDetached: Bool = false,
        isPrimary: Bool = false,
        isLocked: Bool = false,
        lockReason: String? = nil,
        isPrunable: Bool = false,
        pruneReason: String? = nil
    ) {
        self.path = path
        self.branch = branch
        self.head = head
        self.isDetached = isDetached
        self.isPrimary = isPrimary
        self.isLocked = isLocked
        self.lockReason = lockReason
        self.isPrunable = isPrunable
        self.pruneReason = pruneReason
    }

    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    // Unprefixed aliases mirror Git's porcelain field names.
    public var detached: Bool { isDetached }
    public var primary: Bool { isPrimary }
    public var locked: Bool { isLocked }
    public var prunable: Bool { isPrunable }
}
