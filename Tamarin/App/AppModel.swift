import AppKit
import Foundation
import GhosttyTerminal
import Observation

struct WorktreeSelection: Hashable, Sendable {
    let repositoryID: UUID
    let path: String
}

struct AppNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

enum SetupExecutionState: Equatable {
    case running
    case succeeded
    case failed(String)
}

@MainActor
@Observable
final class AppModel {
    var repositories: [RepositoryRecord] = []
    var worktreesByRepository: [UUID: [WorktreeInfo]] = [:]
    var selectedWorktree: WorktreeSelection?

    var terminalSessions: [TerminalTabSession] = []
    var activeTerminalByWorktree: [String: UUID] = [:]
    var detachingTerminalIDs: Set<UUID> = []

    var loadingRepositoryIDs: Set<UUID> = []
    var loadingBranchRepositoryIDs: Set<UUID> = []
    var setupStateByWorktree: [String: SetupExecutionState] = [:]
    var busyMessage: String?
    var notice: AppNotice?

    @ObservationIgnored private let store: RepositoryStore
    @ObservationIgnored private let git: GitService
    @ObservationIgnored private let setupRunner: SetupScriptRunner
    @ObservationIgnored private var hasStarted = false

    init(
        store: RepositoryStore = RepositoryStore(),
        git: GitService = GitService(),
        setupRunner: SetupScriptRunner = SetupScriptRunner()
    ) {
        self.store = store
        self.git = git
        self.setupRunner = setupRunner

        do {
            repositories = try store.load()
        } catch {
            notice = AppNotice(
                title: "Could Not Load Repositories",
                message: error.localizedDescription
            )
        }
    }

    var selectedRepository: RepositoryRecord? {
        guard let selectedWorktree else { return nil }
        return repository(id: selectedWorktree.repositoryID)
    }

    var selectedWorktreeInfo: WorktreeInfo? {
        guard let selectedWorktree else { return nil }
        return worktreesByRepository[selectedWorktree.repositoryID]?
            .first { $0.path == selectedWorktree.path }
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        for repository in repositories {
            await refresh(repositoryID: repository.id, reportErrors: false)
        }

        if selectedWorktree == nil {
            selectFirstAvailableWorktree()
        }
    }

    func repository(id: UUID) -> RepositoryRecord? {
        repositories.first { $0.id == id }
    }

    func worktrees(for repositoryID: UUID) -> [WorktreeInfo] {
        worktreesByRepository[repositoryID] ?? []
    }

    func sessions(for worktreePath: String) -> [TerminalTabSession] {
        terminalSessions.filter { $0.worktreePath == worktreePath }
    }

    func defaultWorktreeRoot(for repository: RepositoryRecord) -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport
            .appending(path: "Tamarin", directoryHint: .isDirectory)
            .appending(path: "Worktrees", directoryHint: .isDirectory)
            .appending(path: repository.id.uuidString, directoryHint: .isDirectory)
    }

    func effectiveWorktreeRoot(for repository: RepositoryRecord) -> URL {
        repository.worktreeRootURL ?? defaultWorktreeRoot(for: repository)
    }

    func addRepository(at selectedURL: URL) async {
        guard busyMessage == nil else { return }
        busyMessage = "Adding repository…"
        defer { busyMessage = nil }

        do {
            let repository = try await git.makeRepository(from: selectedURL)
            let canonicalPath = repository.repositoryURL
                .resolvingSymlinksInPath()
                .standardizedFileURL.path

            if let existing = repositories.first(where: {
                $0.repositoryURL.resolvingSymlinksInPath().standardizedFileURL.path == canonicalPath
            }) {
                await refresh(repositoryID: existing.id)
                if let worktree = worktrees(for: existing.id).first {
                    selectWorktree(repositoryID: existing.id, path: worktree.path)
                }
                return
            }

            repositories.append(repository)
            repositories.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            persistRepositories()
            await refresh(repositoryID: repository.id)
            if let primary = worktrees(for: repository.id).first(where: \.isPrimary)
                ?? worktrees(for: repository.id).first
            {
                selectWorktree(repositoryID: repository.id, path: primary.path)
            }
        } catch {
            present(error, title: "Could Not Add Repository")
        }
    }

    func updateRepository(
        id: UUID,
        name: String,
        worktreeRoot: String,
        setupScript: String
    ) {
        guard let index = repositories.firstIndex(where: { $0.id == id }) else { return }

        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedRoot = worktreeRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedScript = setupScript.trimmingCharacters(in: .whitespacesAndNewlines)

        repositories[index].name = cleanedName.isEmpty
            ? repositories[index].repositoryURL.lastPathComponent
            : cleanedName
        repositories[index].worktreeRoot = cleanedRoot.isEmpty
            ? nil
            : URL(
                fileURLWithPath: NSString(string: cleanedRoot).expandingTildeInPath,
                isDirectory: true
            ).standardizedFileURL.path
        repositories[index].setupScript = cleanedScript.isEmpty ? nil : setupScript
        repositories.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persistRepositories()
    }

    func forgetRepository(id: UUID) {
        guard !terminalSessions.contains(where: { $0.repositoryID == id }) else {
            notice = AppNotice(
                title: "Close Repository Terminals First",
                message: "Close every terminal for this repository before removing it from Tamarin. No Git worktrees will be deleted."
            )
            return
        }

        repositories.removeAll { $0.id == id }
        worktreesByRepository[id] = nil
        if selectedWorktree?.repositoryID == id {
            selectedWorktree = nil
            selectFirstAvailableWorktree()
        }
        persistRepositories()
    }

    func refresh(repositoryID: UUID, reportErrors: Bool = true) async {
        guard let repository = repository(id: repositoryID) else { return }
        loadingRepositoryIDs.insert(repositoryID)
        defer { loadingRepositoryIDs.remove(repositoryID) }

        do {
            let worktrees = try await git.listWorktrees(in: repository)
            worktreesByRepository[repositoryID] = worktrees

            if selectedWorktree?.repositoryID == repositoryID,
               !worktrees.contains(where: { $0.path == selectedWorktree?.path })
            {
                if let replacement = worktrees.first(where: \.isPrimary) ?? worktrees.first {
                    selectWorktree(repositoryID: repositoryID, path: replacement.path)
                } else {
                    selectedWorktree = nil
                }
            }
        } catch {
            worktreesByRepository[repositoryID] = []
            if reportErrors {
                present(error, title: "Could Not Refresh \(repository.name)")
            }
        }
    }

    func loadBranches(repositoryID: UUID) async -> [GitBranch] {
        guard let repository = repository(id: repositoryID) else { return [] }
        loadingBranchRepositoryIDs.insert(repositoryID)
        defer { loadingBranchRepositoryIDs.remove(repositoryID) }

        do {
            let knownWorktrees = worktreesByRepository[repositoryID]
            return try await git.listBranches(in: repository, worktrees: knownWorktrees)
        } catch {
            present(error, title: "Could Not Load Branches")
            return []
        }
    }

    @discardableResult
    func createWorktree(repositoryID: UUID, branch: GitBranch) async -> Bool {
        guard busyMessage == nil, let repository = repository(id: repositoryID) else {
            return false
        }
        guard !branch.isCheckedOut else {
            notice = AppNotice(
                title: "Branch Already Checked Out",
                message: branch.checkoutPath.map { "This branch is already checked out at \($0)." }
                    ?? "This branch is already checked out in another worktree."
            )
            return false
        }

        let root = effectiveWorktreeRoot(for: repository)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let repositoryURL = repository.repositoryURL
            .resolvingSymlinksInPath()
            .standardizedFileURL

        guard !Self.pathsContainEachOther(root.path, repositoryURL.path) else {
            notice = AppNotice(
                title: "Choose a Different Worktree Directory",
                message: "The worktree directory and repository cannot contain one another. Change the directory in Repository Settings."
            )
            return false
        }

        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            present(error, title: "Could Not Create Worktree Directory")
            return false
        }

        let destination = uniqueDestination(in: root, branchName: branch.localBranchName)
        busyMessage = "Creating \(branch.localBranchName)…"

        let createdWorktree: WorktreeInfo
        do {
            createdWorktree = try await git.createWorktree(
                repository: repository,
                branch: branch,
                at: destination
            )
        } catch {
            busyMessage = nil
            present(error, title: "Could Not Create Worktree")
            return false
        }

        await refresh(repositoryID: repositoryID, reportErrors: false)
        selectWorktree(repositoryID: repositoryID, path: createdWorktree.path)

        var setupFailure: String?
        if let script = repository.setupScript,
           !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            busyMessage = "Running setup script…"
            setupStateByWorktree[createdWorktree.path] = .running
            do {
                let result = try await setupRunner.run(script: script, in: createdWorktree.url)
                if result.succeeded {
                    setupStateByWorktree[createdWorktree.path] = .succeeded
                } else {
                    let output = Self.processOutput(result)
                    setupFailure = output.isEmpty
                        ? "The setup script exited with status \(result.terminationStatus)."
                        : output
                    setupStateByWorktree[createdWorktree.path] = .failed(setupFailure!)
                }
            } catch {
                setupFailure = error.localizedDescription
                setupStateByWorktree[createdWorktree.path] = .failed(error.localizedDescription)
            }
        }

        busyMessage = nil
        _ = createTerminal(repositoryID: repositoryID, worktreePath: createdWorktree.path)

        if let setupFailure {
            notice = AppNotice(
                title: "Worktree Created; Setup Failed",
                message: Self.limited(setupFailure)
            )
        }
        return true
    }

    func removeWorktree(repositoryID: UUID, path: String) async {
        guard busyMessage == nil,
              let repository = repository(id: repositoryID),
              let worktree = worktrees(for: repositoryID).first(where: { $0.path == path })
        else { return }

        guard !worktree.isPrimary else {
            notice = AppNotice(
                title: "Repository Worktree Cannot Be Removed",
                message: "Tamarin will not remove the repository's primary checkout."
            )
            return
        }
        guard sessions(for: path).isEmpty else {
            notice = AppNotice(
                title: "Close Terminals First",
                message: "Close every terminal in this worktree before removing it."
            )
            return
        }

        busyMessage = "Removing worktree…"
        defer { busyMessage = nil }

        do {
            try await git.removeWorktree(repository: repository, path: worktree.url)
            setupStateByWorktree[path] = nil
            await refresh(repositoryID: repositoryID, reportErrors: false)
            if selectedWorktree?.path == path {
                if let replacement = worktrees(for: repositoryID).first {
                    selectWorktree(repositoryID: repositoryID, path: replacement.path)
                } else {
                    selectedWorktree = nil
                }
            }
        } catch {
            present(error, title: "Could Not Remove Worktree")
        }
    }

    func selectWorktree(repositoryID: UUID, path: String) {
        selectedWorktree = WorktreeSelection(repositoryID: repositoryID, path: path)
        updateTerminalVisibility(requestFocus: true)
    }

    @discardableResult
    func createTerminal(
        repositoryID: UUID? = nil,
        worktreePath: String? = nil
    ) -> TerminalTabSession? {
        let repositoryID = repositoryID ?? selectedWorktree?.repositoryID
        let worktreePath = worktreePath ?? selectedWorktree?.path
        guard let repositoryID, let worktreePath else { return nil }
        guard FileManager.default.fileExists(atPath: worktreePath) else {
            notice = AppNotice(
                title: "Worktree Is Missing",
                message: "The worktree directory no longer exists. Refresh the repository and try again."
            )
            return nil
        }

        let nextOrdinal = (sessions(for: worktreePath).map(\.ordinal).max() ?? 0) + 1
        let session = TerminalTabSession(
            repositoryID: repositoryID,
            worktreePath: worktreePath,
            ordinal: nextOrdinal
        )
        terminalSessions.append(session)
        activeTerminalByWorktree[worktreePath] = session.id
        selectedWorktree = WorktreeSelection(repositoryID: repositoryID, path: worktreePath)
        updateTerminalVisibility(requestFocus: true)
        return session
    }

    func selectTerminal(_ id: UUID) {
        guard let session = terminalSessions.first(where: { $0.id == id }) else { return }
        selectedWorktree = WorktreeSelection(
            repositoryID: session.repositoryID,
            path: session.worktreePath
        )
        activeTerminalByWorktree[session.worktreePath] = id
        updateTerminalVisibility(requestFocus: true)
    }

    func closeTerminal(_ id: UUID) {
        guard let session = terminalSessions.first(where: { $0.id == id }),
              !detachingTerminalIDs.contains(id)
        else { return }

        // First remove the native view from the host ZStack while retaining its
        // model. Releasing the runtime on a later turn prevents Ghostty's layer
        // callback from racing a Core Animation transaction during teardown.
        detachingTerminalIDs.insert(id)
        session.terminal.isSurfaceVisible = false

        if activeTerminalByWorktree[session.worktreePath] == id {
            activeTerminalByWorktree[session.worktreePath] = sessions(for: session.worktreePath)
                .first { $0.id != id && !detachingTerminalIDs.contains($0.id) }?.id
        }
        updateTerminalVisibility(requestFocus: true)

        Task { @MainActor [weak self] in
            await Task.yield()
            await Task.yield()
            guard let self else { return }
            terminalSessions.removeAll { $0.id == id }
            detachingTerminalIDs.remove(id)
            updateTerminalVisibility(requestFocus: true)
        }
    }

    func isActive(_ session: TerminalTabSession) -> Bool {
        selectedWorktree?.path == session.worktreePath
            && activeTerminalByWorktree[session.worktreePath] == session.id
            && !detachingTerminalIDs.contains(session.id)
    }

    func isMounted(_ session: TerminalTabSession) -> Bool {
        !detachingTerminalIDs.contains(session.id)
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: path, isDirectory: true),
        ])
    }

    private func selectFirstAvailableWorktree() {
        for repository in repositories {
            if let worktree = worktrees(for: repository.id).first(where: \.isPrimary)
                ?? worktrees(for: repository.id).first
            {
                selectWorktree(repositoryID: repository.id, path: worktree.path)
                return
            }
        }
    }

    private func updateTerminalVisibility(requestFocus: Bool) {
        var focusedTerminal: TerminalTabSession?
        for session in terminalSessions {
            let active = isActive(session)
            if session.terminal.isSurfaceVisible != active {
                session.terminal.isSurfaceVisible = active
            }
            if active { focusedTerminal = session }
        }

        guard requestFocus, let focusedTerminal else { return }
        Task { @MainActor [weak terminal = focusedTerminal.terminal] in
            await Task.yield()
            terminal?.requestFocus()
        }
    }

    private func uniqueDestination(in root: URL, branchName: String) -> URL {
        let slug = Self.pathSlug(branchName)
        let existingPaths = Set(
            worktreesByRepository.values
                .flatMap { $0 }
                .map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }
        )

        var candidate = root.appending(path: slug, directoryHint: .isDirectory)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path)
            || existingPaths.contains(candidate.standardizedFileURL.path)
        {
            candidate = root.appending(path: "\(slug)-\(suffix)", directoryHint: .isDirectory)
            suffix += 1
        }
        return candidate
    }

    private func persistRepositories() {
        do {
            try store.save(repositories)
        } catch {
            present(error, title: "Could Not Save Repository Settings")
        }
    }

    private func present(_ error: Error, title: String) {
        notice = AppNotice(title: title, message: Self.limited(error.localizedDescription))
    }

    private static func pathSlug(_ branchName: String) -> String {
        var slug = branchName.replacingOccurrences(
            of: "[^A-Za-z0-9._-]+",
            with: "-",
            options: .regularExpression
        )
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        return slug.isEmpty ? "worktree" : String(slug.prefix(80))
    }

    private static func pathsContainEachOther(_ lhs: String, _ rhs: String) -> Bool {
        let left = URL(fileURLWithPath: lhs).standardizedFileURL.pathComponents
        let right = URL(fileURLWithPath: rhs).standardizedFileURL.pathComponents
        return left.starts(with: right) || right.starts(with: left)
    }

    private static func processOutput(_ result: ProcessResult) -> String {
        [result.stdout, result.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private static func limited(_ text: String) -> String {
        guard text.count > 8_000 else { return text }
        return String(text.suffix(8_000))
    }
}
