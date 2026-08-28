import SwiftUI

struct CreateWorktreeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let repositoryID: UUID

    @State private var branches: [GitBranch] = []
    @State private var searchText = ""
    @State private var selectedBranchID: GitBranch.ID?
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Create Worktree")
                        .font(.title2.weight(.semibold))
                    Text(repository?.name ?? "Repository")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await loadBranches() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading || model.busyMessage != nil)
                .help("Reload local refs")
            }
            .padding(20)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search branches", text: $searchText)
                    .textFieldStyle(.plain)
                    .onSubmit(selectFirstAvailableBranch)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider()

            Group {
                if isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Loading branches…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredBranches.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List(filteredBranches, selection: $selectedBranchID) { branch in
                        branchRow(branch)
                            .tag(branch.id)
                    }
                    .listStyle(.inset)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                if let repository {
                    LabeledContent("Worktree directory") {
                        Text(model.effectiveWorktreeRoot(for: repository).path)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(model.effectiveWorktreeRoot(for: repository).path)
                    }
                    .font(.caption)

                    if repository.setupScript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                        Label(
                            "The repository setup script will run after Git creates the worktree.",
                            systemImage: "terminal"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Create Worktree") {
                        createSelectedBranch()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedBranch == nil || model.busyMessage != nil)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 620, minHeight: 540)
        .task(id: repositoryID) {
            await loadBranches()
        }
        .interactiveDismissDisabled(model.busyMessage != nil)
    }

    private var repository: RepositoryRecord? {
        model.repository(id: repositoryID)
    }

    private var filteredBranches: [GitBranch] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return branches }
        let terms = query.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        return branches.filter { branch in
            let candidate = "\(branch.displayName) \(branch.localBranchName)".lowercased()
            return terms.allSatisfy(candidate.contains)
        }
    }

    private var selectedBranch: GitBranch? {
        guard let selectedBranchID else { return nil }
        return branches.first { $0.id == selectedBranchID && !$0.isCheckedOut }
    }

    private func branchRow(_ branch: GitBranch) -> some View {
        HStack(spacing: 10) {
            Image(systemName: branch.kind == .local ? "arrow.triangle.branch" : "network")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(branch.displayName)
                    .lineLimit(1)
                if branch.kind == .remote {
                    Text("Creates local branch \(branch.localBranchName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let checkoutPath = branch.checkoutPath {
                    Text("Checked out at \(checkoutPath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()
            Text(branch.kind == .local ? "Local" : "Remote")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
            if branch.isCheckedOut {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .help("Already checked out")
            }
        }
        .padding(.vertical, 4)
        .opacity(branch.isCheckedOut ? 0.55 : 1)
        .allowsHitTesting(!branch.isCheckedOut)
    }

    private func loadBranches() async {
        isLoading = true
        branches = await model.loadBranches(repositoryID: repositoryID)
        isLoading = false
        if selectedBranch == nil {
            selectedBranchID = filteredBranches.first(where: { !$0.isCheckedOut })?.id
        }
    }

    private func selectFirstAvailableBranch() {
        selectedBranchID = filteredBranches.first(where: { !$0.isCheckedOut })?.id
    }

    private func createSelectedBranch() {
        guard let selectedBranch else { return }
        Task {
            if await model.createWorktree(
                repositoryID: repositoryID,
                branch: selectedBranch
            ) {
                dismiss()
            }
        }
    }
}
