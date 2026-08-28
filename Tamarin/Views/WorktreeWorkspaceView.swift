import GhosttyTerminal
import SwiftUI

struct WorktreeWorkspaceView: View {
    @Environment(AppModel.self) private var model
    let addRepository: () -> Void

    @State private var renameSessionID: UUID?
    @State private var renameText = ""
    @State private var showingRename = false
    @State private var showingRemoveConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Divider()
            terminalTabBar
            Divider()
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                TerminalDeckView()

                if let worktree = model.selectedWorktreeInfo {
                    selectedWorktreeOverlay(worktree)
                } else {
                    noSelectionView
                }
            }
        }
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
            Text("Leave the name empty to use the title reported by the shell.")
        }
        .confirmationDialog(
            "Remove this worktree?",
            isPresented: $showingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Worktree", role: .destructive) {
                guard let selection = model.selectedWorktree else { return }
                Task {
                    await model.removeWorktree(
                        repositoryID: selection.repositoryID,
                        path: selection.path
                    )
                }
            }
        } message: {
            Text("Git will refuse if the worktree contains changes that would be lost. The branch is not deleted.")
        }
    }

    @ViewBuilder
    private var workspaceHeader: some View {
        if let repository = model.selectedRepository,
           let worktree = model.selectedWorktreeInfo
        {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(worktree.branch ?? "Detached HEAD")
                        .font(.headline)
                    Text("\(repository.name) · \(worktree.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if worktree.isPrimary {
                    statusBadge("Repository", systemImage: "shippingbox")
                }
                if worktree.isLocked {
                    statusBadge("Locked", systemImage: "lock")
                }

                Spacer()
                Button {
                    model.reveal(worktree.path)
                } label: {
                    Image(systemName: "finder")
                }
                .help("Reveal in Finder")

                Button {
                    _ = model.createTerminal()
                } label: {
                    Label("New Terminal", systemImage: "plus.rectangle.on.rectangle")
                }
                .disabled(worktree.isPrunable)

                if !worktree.isPrimary {
                    Button(role: .destructive) {
                        showingRemoveConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(!model.sessions(for: worktree.path).isEmpty || worktree.isLocked)
                    .help(removalHelp(worktree))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 57)
        } else {
            HStack {
                Text("Worktree")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 57)
        }
    }

    @ViewBuilder
    private var terminalTabBar: some View {
        if let selection = model.selectedWorktree {
            let sessions = model.sessions(for: selection.path)
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(sessions) { session in
                        terminalTab(session)
                    }

                    Button {
                        _ = model.createTerminal()
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("New terminal")
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.hidden)
            .frame(height: 39)
            .background(.bar)
        } else {
            Color.clear.frame(height: 39)
        }
    }

    private func terminalTab(_ session: TerminalTabSession) -> some View {
        let active = model.activeTerminalByWorktree[session.worktreePath] == session.id

        return HStack(spacing: 3) {
            Button {
                model.selectTerminal(session.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: session.isExited ? "xmark.circle" : "terminal")
                        .font(.caption)
                    Text(session.title)
                        .font(.caption)
                        .lineLimit(1)
                        .frame(maxWidth: 180)
                }
                .padding(.leading, 8)
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    beginRename(session)
                }
            )

            Button {
                model.closeTerminal(session.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 19, height: 19)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 3)
            .help("Close terminal")
        }
        .background(active ? Color.accentColor.opacity(0.17) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(active ? Color.accentColor.opacity(0.35) : .clear, lineWidth: 1)
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

    private func statusBadge(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
    }

    private func beginRename(_ session: TerminalTabSession) {
        renameSessionID = session.id
        renameText = session.customTitle ?? session.title
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
