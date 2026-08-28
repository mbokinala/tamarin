import AppKit
import GhosttyTerminal
import SwiftUI

struct WorktreeWorkspaceView: View {
    @Environment(AppModel.self) private var model
    let addRepository: () -> Void
    let isSidebarVisible: Bool
    let toggleSidebar: () -> Void

    @State private var renameSessionID: UUID?
    @State private var renameText = ""
    @State private var showingRename = false
    @State private var showingForceRemoveConfirmation = false
    @State private var pendingForceRemoval: WorktreeSelection?
    @State private var hoveredSessionID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader
            terminalTabBar
            Divider()
            ZStack {
                TerminalDeckView()

                if let worktree = model.selectedWorktreeInfo {
                    selectedWorktreeOverlay(worktree)
                } else {
                    noSelectionView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Rename Terminal", isPresented: $showingRename) {
            TextField("Terminal name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                guard let renameSessionID,
                      let session = model.terminalSessions.first(where: { $0.id == renameSessionID })
                else { return }
                session.rename(to: renameText)
            }
        } message: {
            Text("Leave the name empty to restore the default terminal name.")
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
    }

    @ViewBuilder
    private var workspaceHeader: some View {
        if let repository = model.selectedRepository,
           let worktree = model.selectedWorktreeInfo
        {
            HStack(spacing: 10) {
                sidebarToggleButton

                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text(worktreeTitle(worktree))
                            .font(.headline)
                            .lineLimit(1)

                        if worktree.isLocked {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help(worktree.lockReason ?? "This worktree is locked")
                        }
                    }

                    Text("\(repository.name) · \(abbreviatedPath(worktree.path))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    model.reveal(worktree.path)
                } label: {
                    Image(systemName: "finder")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")

                if !worktree.isPrimary {
                    Button(role: .destructive) {
                        guard let selection = model.selectedWorktree else { return }
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
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(!model.sessions(for: worktree.path).isEmpty || worktree.isLocked)
                    .help(removalHelp(worktree))
                }
            }
            .padding(.horizontal, 16)
            .padding(.leading, isSidebarVisible ? 0 : 62)
            .frame(height: 44)
        } else {
            HStack {
                sidebarToggleButton

                Text("Worktree")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.leading, isSidebarVisible ? 0 : 62)
            .frame(height: 44)
        }
    }

    private var sidebarToggleButton: some View {
        Button(action: toggleSidebar) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("s", modifiers: [.command, .control])
        .help(isSidebarVisible ? "Hide Sidebar" : "Show Sidebar")
        .accessibilityLabel(isSidebarVisible ? "Hide Sidebar" : "Show Sidebar")
    }

    @ViewBuilder
    private var terminalTabBar: some View {
        if let selection = model.selectedWorktree {
            let sessions = model.sessions(for: selection.path)
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(sessions) { session in
                        terminalTab(session)
                    }

                    Button {
                        _ = model.createTerminal()
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.selectedWorktreeInfo?.isPrunable == true)
                    .help("New terminal")
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)
            .frame(height: 34)
            .background(Color(nsColor: .controlBackgroundColor))
        } else {
            Color(nsColor: .controlBackgroundColor).frame(height: 34)
        }
    }

    private func terminalTab(_ session: TerminalTabSession) -> some View {
        let active = model.activeTerminalByWorktree[session.worktreePath] == session.id

        let hovered = hoveredSessionID == session.id

        return HStack(spacing: 0) {
            Button {
                model.selectTerminal(session.id)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: session.isExited ? "xmark.circle" : "terminal")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(session.tabTitle)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(minWidth: 70, maxWidth: 180, alignment: .leading)
                }
                .padding(.leading, 9)
                .padding(.trailing, 5)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    beginRename(session)
                }
            )
            .help(session.title)

            Button {
                model.closeTerminal(session.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 19, height: 19)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .padding(.trailing, 5)
            .opacity(active || hovered ? 0.75 : 0)
            .allowsHitTesting(active || hovered)
            .help("Close terminal")
        }
        .frame(minWidth: 116, maxWidth: 230, alignment: .leading)
        .frame(height: 34)
        .contentShape(Rectangle())
        .background(active ? Color(nsColor: .windowBackgroundColor) : Color.clear)
        .overlay(alignment: .bottom) {
            if active {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.55))
                .frame(width: 1)
                .padding(.vertical, 7)
        }
        .onHover { isHovering in
            hoveredSessionID = isHovering ? session.id : nil
        }
        .contextMenu {
            Button("Rename…") { beginRename(session) }
            Button("Close") { model.closeTerminal(session.id) }
        }
    }

    @ViewBuilder
    private func selectedWorktreeOverlay(_ worktree: WorktreeInfo) -> some View {
        let sessions = model.sessions(for: worktree.path)
        let active = sessions.first {
            model.activeTerminalByWorktree[worktree.path] == $0.id
        }

        if sessions.isEmpty {
            ContentUnavailableView {
                Label("No Terminals", systemImage: "terminal")
            } description: {
                Text("Create a terminal in this worktree.")
            } actions: {
                Button("New Terminal") { _ = model.createTerminal() }
                    .disabled(worktree.isPrunable)
            }
        } else if let active, active.isExited {
            ContentUnavailableView {
                Label("Terminal Exited", systemImage: "rectangle.portrait.and.arrow.right")
            } description: {
                Text("The shell for “\(active.title)” has ended.")
            } actions: {
                HStack {
                    Button("Close Tab") { model.closeTerminal(active.id) }
                    Button("New Terminal") { _ = model.createTerminal() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .background(.ultraThinMaterial)
        }

        if let setupState = model.setupStateByWorktree[worktree.path] {
            setupBanner(setupState)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(12)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var noSelectionView: some View {
        if model.repositories.isEmpty {
            ContentUnavailableView {
                Label("Start with a Repository", systemImage: "folder.badge.plus")
            } description: {
                Text("Add a Git repository, then create worktrees and terminals for its branches.")
            } actions: {
                Button("Add Repository…", action: addRepository)
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView(
                "Select a Worktree",
                systemImage: "arrow.triangle.branch",
                description: Text("Choose a worktree from the sidebar.")
            )
        }
    }

    private func setupBanner(_ state: SetupExecutionState) -> some View {
        HStack(spacing: 8) {
            switch state {
            case .running:
                ProgressView().controlSize(.small)
                Text("Running repository setup…")
            case .succeeded:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Repository setup completed")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Repository setup failed")
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
    }

    private func worktreeTitle(_ worktree: WorktreeInfo) -> String {
        if worktree.isDetached, let head = worktree.head {
            return "Detached · \(head.prefix(8))"
        }
        return worktree.branch ?? "Worktree"
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + String(path.dropFirst(home.count))
    }

    private func beginRename(_ session: TerminalTabSession) {
        renameSessionID = session.id
        renameText = session.customTitle ?? session.tabTitle
        showingRename = true
    }

    private func removalHelp(_ worktree: WorktreeInfo) -> String {
        if worktree.isLocked { return "This worktree is locked" }
        if !model.sessions(for: worktree.path).isEmpty {
            return "Close every terminal before removing this worktree"
        }
        return "Remove worktree"
    }
}

private struct TerminalDeckView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            ForEach(model.terminalSessions) { session in
                if model.isMounted(session) {
                    let active = model.isActive(session)
                    TerminalSurfaceView(context: session.terminal)
                        .id(session.id)
                        .opacity(active ? 1 : 0)
                        .allowsHitTesting(active)
                        .accessibilityHidden(!active)
                        .zIndex(active ? 1 : 0)
                }
            }
        }
        .clipped()
    }
}
