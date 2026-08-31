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

private enum AppKeyboardShortcut: Sendable {
    case newTerminal
    case closeTerminal
    case quitApplication
    case previousWorktree
    case nextWorktree
}

enum SetupExecutionState: Equatable {
    case running
    case succeeded
    case failed(String)
}

enum WorktreeRemovalResult {
    case removed
    case requiresForce
    case failed
}

private enum WorktreeCreationRequest {
    case existing(GitBranch)
    case new(name: String, startPoint: GitBranch)

    var branchName: String {
        switch self {
        case let .existing(branch): branch.localBranchName
        case let .new(name, _): name
        }
    }
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
    @ObservationIgnored private let configurationStore: RepositoryConfigurationStore
    @ObservationIgnored private var teardownPreparedForForceRemoval: Set<String> = []
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var keyboardShortcutMonitor: Any?

    init(
        store: RepositoryStore = RepositoryStore(),
        git: GitService = GitService(),
        setupRunner: SetupScriptRunner = SetupScriptRunner(),
        configurationStore: RepositoryConfigurationStore = RepositoryConfigurationStore()
    ) {
        self.store = store
        self.git = git
        self.setupRunner = setupRunner
        self.configurationStore = configurationStore

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
        installKeyboardShortcutMonitor()

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

    var canCreateTerminal: Bool {
        selectedWorktree != nil && selectedWorktreeInfo?.isPrunable != true
    }

    var canCloseActiveTerminal: Bool {
        activeTerminalSession != nil
    }

    var canSelectNextWorktree: Bool {
        orderedWorktreeSelections.count > 1
    }

    var canSelectPreviousWorktree: Bool {
        orderedWorktreeSelections.count > 1
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

    /// The primary checkout owns repository-scoped settings even when the
    /// repository was originally added from one of its linked worktrees.
    func baseRepositoryURL(for repository: RepositoryRecord) -> URL {
        worktrees(for: repository.id).first(where: \.isPrimary)?.url
            ?? repository.repositoryURL
    }

    func configurationFileURL(for repository: RepositoryRecord) -> URL {
        configurationStore.fileURL(in: baseRepositoryURL(for: repository))
    }

    func lifecycleConfiguration(
        for repository: RepositoryRecord
    ) throws -> RepositoryLifecycleConfiguration {
        if let configuration = try configurationStore.load(
            from: baseRepositoryURL(for: repository)
        ) {
            return configuration
        }

        // Let existing users migrate their setup script the next time they save
        // Repository Settings. New scripts are written only to the TOML file.
        return RepositoryLifecycleConfiguration(setupScript: repository.setupScript)
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

    @discardableResult
    func updateRepository(
        id: UUID,
        name: String,
        worktreeRoot: String,
        setupScript: String,
        teardownScript: String
    ) -> Bool {
        guard let index = repositories.firstIndex(where: { $0.id == id }) else { return false }

        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedRoot = worktreeRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let lifecycleConfiguration = RepositoryLifecycleConfiguration(
            setupScript: setupScript,
            teardownScript: teardownScript
        )

        do {
            try configurationStore.save(
                lifecycleConfiguration,
                in: baseRepositoryURL(for: repositories[index])
            )
        } catch {
            present(error, title: "Could Not Save Repository Configuration")
            return false
        }

        repositories[index].name = cleanedName.isEmpty
            ? repositories[index].repositoryURL.lastPathComponent
            : cleanedName
        repositories[index].worktreeRoot = cleanedRoot.isEmpty
            ? nil
            : URL(
                fileURLWithPath: NSString(string: cleanedRoot).expandingTildeInPath,
                isDirectory: true
            ).standardizedFileURL.path
        repositories[index].setupScript = nil
        repositories.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return persistRepositories()
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
        guard !branch.isCheckedOut else {
            notice = AppNotice(
                title: "Branch Already Checked Out",
                message: branch.checkoutPath.map { "This branch is already checked out at \($0)." }
                    ?? "This branch is already checked out in another worktree."
            )
            return false
        }

        return await createWorktree(
            repositoryID: repositoryID,
            request: .existing(branch)
        )
    }

    @discardableResult
    func createWorktree(
        repositoryID: UUID,
        newBranchName: String,
        startingAt startPoint: GitBranch
    ) async -> Bool {
        let branchName = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branchName.isEmpty else {
            notice = AppNotice(
                title: "Branch Name Required",
                message: "Enter a name for the new branch."
            )
            return false
        }

        return await createWorktree(
            repositoryID: repositoryID,
            request: .new(name: branchName, startPoint: startPoint)
        )
    }

    private func createWorktree(
        repositoryID: UUID,
        request: WorktreeCreationRequest
    ) async -> Bool {
        guard busyMessage == nil, let repository = repository(id: repositoryID) else {
            return false
        }

        let root = effectiveWorktreeRoot(for: repository)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let repositoryURL = repository.repositoryURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let baseRepositoryURL = baseRepositoryURL(for: repository)
            .resolvingSymlinksInPath()
            .standardizedFileURL

        guard !Self.pathsContainEachOther(root.path, repositoryURL.path) else {
            notice = AppNotice(
                title: "Choose a Different Worktree Directory",
                message: "The worktree directory and repository cannot contain one another. Change the directory in Repository Settings."
            )
            return false
        }

        let lifecycleConfiguration: RepositoryLifecycleConfiguration
        do {
            lifecycleConfiguration = try self.lifecycleConfiguration(for: repository)
        } catch {
            present(error, title: "Could Not Read Repository Configuration")
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

        let branchName = request.branchName
        let destination = uniqueDestination(in: root, branchName: branchName)
        busyMessage = "Creating \(branchName)…"

        let createdWorktree: WorktreeInfo
        do {
            switch request {
            case let .existing(branch):
                createdWorktree = try await git.createWorktree(
                    repository: repository,
                    branch: branch,
                    at: destination
                )
            case let .new(name, startPoint):
                createdWorktree = try await git.createWorktree(
                    repository: repository,
                    newBranchNamed: name,
                    startingAt: startPoint,
                    at: destination
                )
            }
        } catch {
            busyMessage = nil
            present(error, title: "Could Not Create Worktree")
            return false
        }

        await refresh(repositoryID: repositoryID, reportErrors: false)
        selectWorktree(repositoryID: repositoryID, path: createdWorktree.path)

        if let script = lifecycleConfiguration.setupScript {
            busyMessage = "Running setup script…"
            setupStateByWorktree[createdWorktree.path] = .running
            let outputSession = SetupOutputSession()
            outputSession.receive(Self.setupOutputHeader(worktreePath: createdWorktree.path))
            _ = createSetupOutputTerminal(
                repositoryID: repositoryID,
                worktreePath: createdWorktree.path,
                outputSession: outputSession
            )

            Task { @MainActor [weak self] in
                await self?.finishSetup(
                    script: script,
                    repositoryID: repositoryID,
                    baseRepositoryURL: baseRepositoryURL,
                    worktree: createdWorktree,
                    outputSession: outputSession
                )
            }
            return true
        }

        busyMessage = nil
        _ = createTerminal(repositoryID: repositoryID, worktreePath: createdWorktree.path)
        return true
    }

    private func finishSetup(
        script: String,
        repositoryID: UUID,
        baseRepositoryURL: URL,
        worktree: WorktreeInfo,
        outputSession: SetupOutputSession
    ) async {
        do {
            let result = try await setupRunner.runCapturingResult(
                script: script,
                phase: .setup,
                baseRepositoryDirectory: baseRepositoryURL,
                worktreeDirectory: worktree.url,
                standardOutputHandler: { outputSession.receive($0) },
                standardErrorHandler: { outputSession.receive($0) }
            )
            outputSession.receive(Self.setupOutputFooter(result: result))

            if result.succeeded {
                setupStateByWorktree[worktree.path] = .succeeded
            } else {
                let failure = SetupScriptError.lifecycleFailed(
                    phase: .setup,
                    status: result.terminationStatus,
                    detail: Self.processErrorDetail(result)
                )
                setupStateByWorktree[worktree.path] = .failed(
                    failure.localizedDescription
                )
                notice = AppNotice(
                    title: "Worktree Created; Setup Failed",
                    message: "The setup script exited with status \(result.terminationStatus). Review the Setup Output terminal tab for its log."
                )
            }
        } catch {
            outputSession.receive(Self.setupOutputFooter(error: error))
            setupStateByWorktree[worktree.path] = .failed(error.localizedDescription)
            notice = AppNotice(
                title: "Worktree Created; Setup Failed",
                message: "The setup script could not run. Review the Setup Output terminal tab for details."
            )
        }

        busyMessage = nil

        let hasShell = sessions(for: worktree.path).contains { !$0.isSetupOutput }
        guard !hasShell else { return }

        let shouldActivate = selectedWorktree?.path == worktree.path
            && activeTerminalByWorktree[worktree.path] == nil
        _ = createTerminal(
            repositoryID: repositoryID,
            worktreePath: worktree.path,
            activate: shouldActivate
        )
    }

    @discardableResult
    func removeWorktree(
        repositoryID: UUID,
        path: String,
        force: Bool = false
    ) async -> WorktreeRemovalResult {
        guard busyMessage == nil,
              let repository = repository(id: repositoryID),
              let worktree = worktrees(for: repositoryID).first(where: { $0.path == path })
        else { return .failed }

        guard !worktree.isPrimary else {
            notice = AppNotice(
                title: "Repository Worktree Cannot Be Removed",
                message: "Tamarin will not remove the repository's primary checkout."
            )
            return .failed
        }
        guard !worktree.isLocked else {
            notice = AppNotice(
                title: "Locked Worktree Cannot Be Removed",
                message: worktree.lockReason ?? "Unlock this worktree before removing it."
            )
            return .failed
        }
        guard sessions(for: path).isEmpty else {
            notice = AppNotice(
                title: "Close Terminals First",
                message: "Close every terminal in this worktree before removing it."
            )
            return .failed
        }

        let teardownAlreadyRan = force
            && teardownPreparedForForceRemoval.remove(path) != nil
        if !force {
            // A new removal request reruns teardown, including after a force
            // confirmation was previously cancelled.
            teardownPreparedForForceRemoval.remove(path)
        }

        if !teardownAlreadyRan {
            let lifecycleConfiguration: RepositoryLifecycleConfiguration
            do {
                lifecycleConfiguration = try self.lifecycleConfiguration(for: repository)
            } catch {
                present(error, title: "Could Not Read Repository Configuration")
                return .failed
            }

            if let script = lifecycleConfiguration.teardownScript {
                busyMessage = "Running teardown script…"
                do {
                    _ = try await setupRunner.run(
                        script: script,
                        phase: .teardown,
                        baseRepositoryDirectory: baseRepositoryURL(for: repository),
                        worktreeDirectory: worktree.url
                    )
                } catch {
                    busyMessage = nil
                    present(error, title: "Could Not Teardown Worktree")
                    return .failed
                }
            }
        }

        busyMessage = "Removing worktree…"
        defer { busyMessage = nil }

        do {
            try await git.removeWorktree(
                repository: repository,
                path: worktree.url,
                force: force
            )
            teardownPreparedForForceRemoval.remove(path)
            setupStateByWorktree[path] = nil
            await refresh(repositoryID: repositoryID, reportErrors: false)
            if selectedWorktree?.path == path {
                if let replacement = worktrees(for: repositoryID).first {
                    selectWorktree(repositoryID: repositoryID, path: replacement.path)
                } else {
                    selectedWorktree = nil
                }
            }
            return .removed
        } catch GitServiceError.worktreeRemovalRequiresForce(_, _) {
            // Teardown succeeded. A force retry can proceed without running it
            // a second time.
            teardownPreparedForForceRemoval.insert(path)
            return .requiresForce
        } catch {
            present(error, title: "Could Not Remove Worktree")
            return .failed
        }
    }

    func selectWorktree(
        repositoryID: UUID,
        path: String,
        requestTerminalFocus: Bool = true
    ) {
        selectedWorktree = WorktreeSelection(repositoryID: repositoryID, path: path)
        updateTerminalVisibility(requestFocus: requestTerminalFocus)
    }

    @discardableResult
    func selectNextWorktree() -> Bool {
        moveWorktreeSelection(by: 1)
    }

    @discardableResult
    func selectPreviousWorktree() -> Bool {
        moveWorktreeSelection(by: -1)
    }

    private func moveWorktreeSelection(by offset: Int) -> Bool {
        let selections = orderedWorktreeSelections
        guard selections.count > 1 else { return false }

        let targetIndex: Int
        if let selectedWorktree,
           let currentIndex = selections.firstIndex(of: selectedWorktree)
        {
            targetIndex = (currentIndex + offset + selections.count) % selections.count
        } else {
            targetIndex = offset < 0 ? selections.count - 1 : 0
        }

        let selection = selections[targetIndex]
        selectWorktree(
            repositoryID: selection.repositoryID,
            path: selection.path
        )
        return true
    }

    @discardableResult
    func createTerminal(
        repositoryID: UUID? = nil,
        worktreePath: String? = nil,
        activate: Bool = true
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

        let nextOrdinal = (
            sessions(for: worktreePath)
                .filter { !$0.isSetupOutput }
                .map(\.ordinal)
                .max() ?? 0
        ) + 1
        let session = TerminalTabSession(
            repositoryID: repositoryID,
            worktreePath: worktreePath,
            ordinal: nextOrdinal
        )
        terminalSessions.append(session)
        if activate {
            activeTerminalByWorktree[worktreePath] = session.id
            selectedWorktree = WorktreeSelection(repositoryID: repositoryID, path: worktreePath)
        } else if activeTerminalByWorktree[worktreePath] == nil {
            activeTerminalByWorktree[worktreePath] = session.id
        }
        updateTerminalVisibility(requestFocus: activate)
        return session
    }

    @discardableResult
    private func createSetupOutputTerminal(
        repositoryID: UUID,
        worktreePath: String,
        outputSession: SetupOutputSession
    ) -> TerminalTabSession? {
        guard FileManager.default.fileExists(atPath: worktreePath) else { return nil }

        let session = TerminalTabSession(
            repositoryID: repositoryID,
            worktreePath: worktreePath,
            ordinal: 0,
            kind: .setupOutput,
            setupOutputSession: outputSession
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

    @discardableResult
    func closeActiveTerminal() -> Bool {
        guard let session = activeTerminalSession else { return false }
        closeTerminal(session.id)
        return true
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

    private var orderedWorktreeSelections: [WorktreeSelection] {
        repositories.flatMap { repository in
            worktrees(for: repository.id).map { worktree in
                WorktreeSelection(repositoryID: repository.id, path: worktree.path)
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

    private var activeTerminalSession: TerminalTabSession? {
        guard let worktreePath = selectedWorktree?.path,
              let terminalID = activeTerminalByWorktree[worktreePath]
        else { return nil }

        return terminalSessions.first {
            $0.id == terminalID && !detachingTerminalIDs.contains($0.id)
        }
    }

    private func installKeyboardShortcutMonitor() {
        guard keyboardShortcutMonitor == nil else { return }

        keyboardShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard event.window?.sheetParent == nil else { return event }

            let modifiers = event.modifierFlags.intersection([
                .command,
                .control,
                .option,
                .shift,
            ])
            let shortcut: AppKeyboardShortcut
            if modifiers == [.command, .shift] {
                switch event.keyCode {
                case 30: shortcut = .nextWorktree
                case 33: shortcut = .previousWorktree
                default: return event
                }
            } else if modifiers == .command,
                      let key = event.charactersIgnoringModifiers?.lowercased()
            {
                switch key {
                case "t": shortcut = .newTerminal
                case "w": shortcut = .closeTerminal
                case "q": shortcut = .quitApplication
                default: return event
                }
            } else {
                return event
            }

            let isRepeat = event.isARepeat
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handleKeyboardShortcut(shortcut, isRepeat: isRepeat)
            }
            return consumed ? nil : event
        }
    }

    private func handleKeyboardShortcut(
        _ shortcut: AppKeyboardShortcut,
        isRepeat: Bool
    ) -> Bool {
        guard !isRepeat else { return true }

        switch shortcut {
        case .newTerminal:
            guard canCreateTerminal else { return true }
            _ = createTerminal()
            return true

        case .closeTerminal:
            return closeActiveTerminal()

        case .quitApplication:
            NSApplication.shared.terminate(nil)
            return true

        case .previousWorktree:
            _ = selectPreviousWorktree()
            return true

        case .nextWorktree:
            _ = selectNextWorktree()
            return true
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

    @discardableResult
    private func persistRepositories() -> Bool {
        do {
            try store.save(repositories)
            return true
        } catch {
            present(error, title: "Could Not Save Repository Settings")
            return false
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

    private static func processErrorDetail(_ result: ProcessResult) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return stdout.isEmpty ? "The shell did not provide an error message." : stdout
    }

    private static func setupOutputHeader(worktreePath: String) -> String {
        "\u{001B}[1mTamarin Setup\u{001B}[0m\nWorktree: \(worktreePath)\n\n"
    }

    private static func setupOutputFooter(result: ProcessResult) -> String {
        var footer = result.stdoutData.isEmpty && result.stderrData.isEmpty
            ? "No output.\n"
            : ""
        footer += "\n\u{001B}[0m"
        if result.succeeded {
            footer += "\u{001B}[1;32mSetup completed successfully (exit status 0).\u{001B}[0m\n"
        } else {
            footer += "\u{001B}[1;31mSetup failed with exit status \(result.terminationStatus).\u{001B}[0m\n"
        }
        return footer
    }

    private static func setupOutputFooter(error: Error) -> String {
        "\n\u{001B}[1;31mSetup could not run.\u{001B}[0m\n\(error.localizedDescription)\n"
    }

    private static func limited(_ text: String) -> String {
        guard text.count > 8_000 else { return text }
        return String(text.suffix(8_000))
    }
}
