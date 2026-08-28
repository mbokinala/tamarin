import AppKit
import SwiftUI

struct RepositorySidebar: View {
    @Environment(AppModel.self) private var model

    let addRepository: () -> Void
    let createWorktree: (RepositoryRecord) -> Void
    let showSettings: (RepositoryRecord) -> Void

    var body: some View {
        if model.repositories.isEmpty {
            ContentUnavailableView {
                Label("No Repositories", systemImage: "point.3.connected.trianglepath.dotted")
            } description: {
                Text("Add a Git repository to manage its worktrees.")
            } actions: {
                Button("Add Repository…", action: addRepository)
            }
            .padding()
        } else {
            List {
                ForEach(model.repositories) { repository in
                    Section {
                        repositoryWorktrees(repository)
                    } header: {
                        repositoryHeader(repository)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Tamarin")
        }
    }

    @ViewBuilder
    private func repositoryWorktrees(_ repository: RepositoryRecord) -> some View {
        if model.loadingRepositoryIDs.contains(repository.id),
           model.worktrees(for: repository.id).isEmpty
        {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading worktrees…")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        } else if model.worktrees(for: repository.id).isEmpty {
            Text("No worktrees found")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
        } else {
            ForEach(model.worktrees(for: repository.id)) { worktree in
                worktreeRow(worktree, repository: repository)
            }
        }
    }

    private func repositoryHeader(_ repository: RepositoryRecord) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
            Text(repository.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                createWorktree(repository)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help("Create a worktree")

            Button {
                showSettings(repository)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Repository settings")
        }
        .padding(.top, 5)
        .contextMenu {
            Button("Create Worktree…") { createWorktree(repository) }
            Button("Repository Settings…") { showSettings(repository) }
            Divider()
            Button("Reveal Repository in Finder") { model.reveal(repository.path) }
        }
    }

    private func worktreeRow(
        _ worktree: WorktreeInfo,
        repository: RepositoryRecord
    ) -> some View {
        let selected = model.selectedWorktree == WorktreeSelection(
            repositoryID: repository.id,
            path: worktree.path
        )

        return Button {
            model.selectWorktree(repositoryID: repository.id, path: worktree.path)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: worktree.isPrimary ? "shippingbox.fill" : "arrow.triangle.branch")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 17)

                VStack(alignment: .leading, spacing: 2) {
                    Text(worktree.branch ?? detachedTitle(worktree))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Text(worktree.isPrimary ? "Repository" : worktree.url.lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 2)
                if !model.sessions(for: worktree.path).isEmpty {
                    Text("\(model.sessions(for: worktree.path).count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                if worktree.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? Color.accentColor.opacity(0.13) : Color.clear)
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
        .help(worktree.path)
    }

    private func detachedTitle(_ worktree: WorktreeInfo) -> String {
        guard let head = worktree.head else { return "Detached HEAD" }
        return "Detached · \(head.prefix(8))"
    }
}
