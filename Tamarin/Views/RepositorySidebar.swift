import AppKit
import SwiftUI

struct RepositorySidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.controlActiveState) private var controlActiveState

    let addRepository: () -> Void
    let createWorktree: (RepositoryRecord) -> Void
    let showSettings: (RepositoryRecord) -> Void

    @State private var hoveredWorktree: WorktreeSelection?
    @State private var addRepositoryHovered = false
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
    }

    private var repositoryList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.repositories) { repository in
                        VStack(alignment: .leading, spacing: 2) {
                            repositoryHeader(repository)
                            repositoryWorktrees(repository)
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
            .help("Create a worktree")

            Menu {
                Button("Create Worktree…") { createWorktree(repository) }
                Button("Repository Settings…") { showSettings(repository) }
                Divider()
                Button("Reveal in Finder") { model.reveal(repository.path) }
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

        return Button {
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
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(rowBackground(selected: selected, hovered: hovered))
            }
        }
        .buttonStyle(.plain)
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
        .help("\(worktreeTitle(worktree))\n\(worktree.path)")
        .accessibilityLabel(worktreeTitle(worktree))
        .accessibilityValue(selected ? "Selected" : "")
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

        let selections = model.repositories.flatMap { repository in
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
