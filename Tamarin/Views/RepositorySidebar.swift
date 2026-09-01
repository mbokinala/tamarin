import AppKit
import SwiftUI

struct RepositorySidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.controlActiveState) private var controlActiveState

    let addRepository: () -> Void
    let createWorktree: (RepositoryRecord) -> Void
    let showSettings: (RepositoryRecord) -> Void

    @AppStorage("collapsedRepositoryIDs") private var collapsedRepositoryIDsStorage = ""
    @State private var hoveredWorktree: WorktreeSelection?
    @State private var addRepositoryHovered = false
    @State private var showingForceRemoveConfirmation = false
    @State private var pendingForceRemoval: WorktreeSelection?
    @State private var showingRepositoryRemovalConfirmation = false
    @State private var pendingRepositoryRemoval: RepositoryRecord?
    @FocusState private var worktreeNavigationFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if model.repositories.isEmpty {
                emptyState
            } else {
                repositoryList
            }

            Divider()
            addRepositoryButton
        }
        .alert(
            "Force Remove Worktree?",
            isPresented: $showingForceRemoveConfirmation
        ) {
            Button("Cancel", role: .cancel) {
                pendingForceRemoval = nil
            }
            Button("Force Remove", role: .destructive) {
                guard let selection = pendingForceRemoval else { return }
                pendingForceRemoval = nil
                Task {
                    await model.removeWorktree(
                        repositoryID: selection.repositoryID,
                        path: selection.path,
                        force: true
                    )
                }
            }
        } message: {
            Text("Git reports that this worktree can only be removed with force. This permanently deletes its uncommitted changes and untracked files. The branch is not deleted.")
        }
        .confirmationDialog(
            "Remove \(pendingRepositoryRemoval?.name ?? "Repository") from Tamarin?",
            isPresented: $showingRepositoryRemovalConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Repository", role: .destructive) {
                guard let repository = pendingRepositoryRemoval else { return }
                pendingRepositoryRemoval = nil
                model.forgetRepository(id: repository.id)
                if model.repository(id: repository.id) == nil {
                    removeCollapsedRepositoryID(repository.id)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingRepositoryRemoval = nil
            }
        } message: {
            Text("This only removes the repository from Tamarin. It does not delete the repository, its branches, or its worktrees.")
        }
    }

    private var repositoryList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.repositories) { repository in
                        VStack(alignment: .leading, spacing: 2) {
                            repositoryHeader(repository)
                            if !isRepositoryCollapsed(repository.id) {
                                repositoryWorktrees(repository)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.automatic)
            .focusable()
            .focused($worktreeNavigationFocused)
            .focusEffectDisabled()
            .onAppear { worktreeNavigationFocused = true }
            .onMoveCommand(perform: moveWorktreeSelection)
            .onChange(of: model.selectedWorktree) { _, selection in
                guard worktreeNavigationFocused, let selection else { return }
                proxy.scrollTo(selection, anchor: .center)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Repositories", systemImage: "point.3.connected.trianglepath.dotted")
        } description: {
            Text("Add a Git repository to manage its worktrees.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var addRepositoryButton: some View {
        Button(action: addRepository) {
            HStack(spacing: 7) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                Text("Add Repository…")
                    .font(.body.weight(.medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 32)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(addRepositoryHovered ? Color.primary.opacity(0.055) : .clear)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .onHover { addRepositoryHovered = $0 }
        .help("Add a Git repository")
    }

    @ViewBuilder
    private func repositoryWorktrees(_ repository: RepositoryRecord) -> some View {
        let worktrees = model.worktrees(for: repository.id)

        if model.loadingRepositoryIDs.contains(repository.id), worktrees.isEmpty {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 16)
                Text("Loading worktrees…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
        } else if worktrees.isEmpty {
            HStack(spacing: 7) {
                Image(systemName: "tray")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
                Text("No worktrees found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
        } else {
            ForEach(worktrees) { worktree in
                worktreeRow(worktree, repository: repository)
            }
        }
    }

    private func repositoryHeader(_ repository: RepositoryRecord) -> some View {
        HStack(spacing: 7) {
            Button {
                toggleRepository(repository.id)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: isRepositoryCollapsed(repository.id)
                        ? "chevron.right"
                        : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)

                    Image(systemName: "folder.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)

                    Text(repository.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)

                    Spacer(minLength: 4)
                }
                .frame(maxWidth: .infinity, minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(repository.name)
            .accessibilityValue(isRepositoryCollapsed(repository.id) ? "Collapsed" : "Expanded")
            .accessibilityHint(isRepositoryCollapsed(repository.id) ? "Show worktrees" : "Hide worktrees")

            Button {
                createWorktree(repository)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Create a worktree (⇧⌘N)")

            Menu {
                Button("Create Worktree…") { createWorktree(repository) }
                Button("Repository Settings…") { showSettings(repository) }
                Divider()
                Button("Reveal in Finder") { model.reveal(repository.path) }
                Divider()
                Button("Remove Repository…", role: .destructive) {
                    pendingRepositoryRemoval = repository
                    showingRepositoryRemovalConfirmation = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundStyle(.secondary)
            .fixedSize()
            .help("Repository actions")
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 32)
        .contentShape(Rectangle())
        .help(repository.path)
    }

    private func isRepositoryCollapsed(_ repositoryID: UUID) -> Bool {
        collapsedRepositoryIDs.contains(repositoryID)
    }

    private func toggleRepository(_ repositoryID: UUID) {
        var repositoryIDs = collapsedRepositoryIDs
        if !repositoryIDs.insert(repositoryID).inserted {
            repositoryIDs.remove(repositoryID)
        }
        collapsedRepositoryIDs = repositoryIDs
    }

    private func removeCollapsedRepositoryID(_ repositoryID: UUID) {
        var repositoryIDs = collapsedRepositoryIDs
        repositoryIDs.remove(repositoryID)
        collapsedRepositoryIDs = repositoryIDs
    }

    private var collapsedRepositoryIDs: Set<UUID> {
        get {
            Set(
                collapsedRepositoryIDsStorage
                    .split(separator: ",")
                    .compactMap { UUID(uuidString: String($0)) }
            )
        }
        nonmutating set {
            collapsedRepositoryIDsStorage = newValue
                .map(\.uuidString)
                .sorted()
                .joined(separator: ",")
        }
    }

    private func worktreeRow(
        _ worktree: WorktreeInfo,
        repository: RepositoryRecord
    ) -> some View {
        let selection = WorktreeSelection(
            repositoryID: repository.id,
            path: worktree.path
        )
        let selected = model.selectedWorktree == selection
        let hovered = hoveredWorktree == selection

        return HStack(spacing: 0) {
            Button {
                worktreeNavigationFocused = true
                model.selectWorktree(
                    repositoryID: repository.id,
                    path: worktree.path,
                    requestTerminalFocus: false
                )
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: worktreeIcon(worktree))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                        .frame(width: 16)

                    worktreeName(worktree)

                    Spacer(minLength: 4)

                    let terminalCount = model.sessions(for: worktree.path).count
                    if terminalCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "terminal")
                            Text("\(terminalCount)")
                                .monospacedDigit()
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }

                    if worktree.isLocked {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, worktree.isPrimary ? 8 : 4)
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("\(worktreeTitle(worktree))\n\(worktree.path)")
            .accessibilityLabel(worktreeTitle(worktree))
            .accessibilityValue(selected ? "Selected" : "")

            if !worktree.isPrimary {
                Button(role: .destructive) {
                    removeWorktree(selection)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(!model.sessions(for: worktree.path).isEmpty || worktree.isLocked)
                .help(removalHelp(worktree))
                .accessibilityLabel("Remove \(worktreeTitle(worktree))")
                .padding(.trailing, 2)
            }
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(rowBackground(selected: selected, hovered: hovered))
        }
        .focusable(false)
        .onHover { isHovering in
            if isHovering {
                hoveredWorktree = selection
            } else if hoveredWorktree == selection {
                hoveredWorktree = nil
            }
        }
        .contextMenu {
            Button("New Terminal") {
                _ = model.createTerminal(
                    repositoryID: repository.id,
                    worktreePath: worktree.path
                )
            }
            .disabled(worktree.isPrunable)

            Button("Reveal in Finder") { model.reveal(worktree.path) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(worktree.path, forType: .string)
            }
        }
        .id(selection)
    }

    @ViewBuilder
    private func worktreeName(_ worktree: WorktreeInfo) -> some View {
        if let branch = worktree.branch,
           let separator = branch.lastIndex(of: "/")
        {
            let namespace = String(branch[...separator])
            let leaf = String(branch[branch.index(after: separator)...])

            HStack(spacing: 0) {
                Text(namespace)
                    .foregroundStyle(.secondary)
                    .layoutPriority(0)
                Text(leaf)
                    .foregroundStyle(.primary)
                    .layoutPriority(1)
            }
            .font(.body)
            .lineLimit(1)
            .truncationMode(.middle)
        } else {
            Text(worktreeTitle(worktree))
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
        }
    }

    private func rowBackground(selected: Bool, hovered: Bool) -> Color {
        if selected {
            if controlActiveState == .inactive {
                return Color.primary.opacity(0.09)
            }
            return Color.accentColor.opacity(0.16)
        }
        if hovered {
            return Color.primary.opacity(0.055)
        }
        return .clear
    }

    private func worktreeIcon(_ worktree: WorktreeInfo) -> String {
        if worktree.isPrimary { return "folder.fill" }
        if worktree.isDetached { return "point.3.filled.connected.trianglepath.dotted" }
        return "arrow.triangle.branch"
    }

    private func worktreeTitle(_ worktree: WorktreeInfo) -> String {
        if worktree.isDetached, let head = worktree.head {
            return "Detached · \(head.prefix(8))"
        }
        return worktree.branch ?? "Worktree"
    }

    private func removeWorktree(_ selection: WorktreeSelection) {
        Task {
            let result = await model.removeWorktree(
                repositoryID: selection.repositoryID,
                path: selection.path
            )
            if case .requiresForce = result {
                pendingForceRemoval = selection
                showingForceRemoveConfirmation = true
            }
        }
    }

    private func removalHelp(_ worktree: WorktreeInfo) -> String {
        if worktree.isLocked { return "This worktree is locked" }
        if !model.sessions(for: worktree.path).isEmpty {
            return "Close every terminal before removing this worktree"
        }
        return "Remove worktree"
    }

    private func moveWorktreeSelection(_ direction: MoveCommandDirection) {
        let offset: Int
        switch direction {
        case .up:
            offset = -1
        case .down:
            offset = 1
        default:
            return
        }

        let selections = model.repositories
            .filter { !isRepositoryCollapsed($0.id) }
            .flatMap { repository in
                model.worktrees(for: repository.id).map { worktree in
                    WorktreeSelection(repositoryID: repository.id, path: worktree.path)
                }
            }
        guard !selections.isEmpty else { return }

        let targetIndex: Int
        if let current = model.selectedWorktree,
           let currentIndex = selections.firstIndex(of: current)
        {
            targetIndex = min(max(currentIndex + offset, 0), selections.count - 1)
        } else {
            targetIndex = offset < 0 ? selections.count - 1 : 0
        }

        let selection = selections[targetIndex]
        guard selection != model.selectedWorktree else { return }
        model.selectWorktree(
            repositoryID: selection.repositoryID,
            path: selection.path,
            requestTerminalFocus: false
        )
    }
}
