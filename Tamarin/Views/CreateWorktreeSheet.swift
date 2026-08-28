import SwiftUI

private enum WorktreeBranchMode: Hashable {
    case existing
    case new
}

struct CreateWorktreeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let repositoryID: UUID

    @State private var branches: [GitBranch] = []
    @State private var searchText = ""
    @State private var selectedBranchID: GitBranch.ID?
    @State private var branchMode: WorktreeBranchMode = .existing
    @State private var newBranchName = ""
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

            HStack {
                Picker("Branch option", selection: $branchMode) {
                    Text("Existing Branch").tag(WorktreeBranchMode.existing)
                    Text("New Branch").tag(WorktreeBranchMode.new)
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .onChange(of: branchMode) {
                searchText = ""
                selectedBranchID = nil
                selectFirstAvailableBranch()
            }

            if branchMode == .new {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundStyle(.secondary)
                        TextField("New branch name", text: $newBranchName)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 36)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

                    if newBranchAlreadyExists {
                        Label(
                            "A local branch with this name already exists.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.red)
                    } else {
                        Text("The new branch will start from the branch or remote ref selected below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    branchMode == .new ? "Search starting points" : "Search branches",
                    text: $searchText
                )
                .textFieldStyle(.plain)
                .onSubmit(selectFirstAvailableBranch)
                .onKeyPress(.downArrow, phases: [.down, .repeat]) { keyPress in
                    let modifiers = keyPress.modifiers.intersection([
                        .command, .control, .option, .shift,
                    ])
                    guard modifiers.isEmpty else { return .ignored }
                    return moveBranchSelection(by: 1) ? .handled : .ignored
                }
                .onKeyPress(.upArrow, phases: [.down, .repeat]) { keyPress in
                    let modifiers = keyPress.modifiers.intersection([
                        .command, .control, .option, .shift,
                    ])
                    guard modifiers.isEmpty else { return .ignored }
                    return moveBranchSelection(by: -1) ? .handled : .ignored
                }
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
                    ScrollViewReader { proxy in
                        List(filteredBranches, selection: $selectedBranchID) { branch in
                            branchRow(branch)
                                .tag(branch.id)
                                .id(branch.id)
                        }
                        .listStyle(.inset)
                        .onChange(of: selectedBranchID) { _, branchID in
                            guard let branchID else { return }
                            proxy.scrollTo(branchID)
                        }
                    }
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
                        createWorktree()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate || model.busyMessage != nil)
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
        return filteredBranches.first { $0.id == selectedBranchID }
    }

    private var trimmedNewBranchName: String {
        newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var newBranchAlreadyExists: Bool {
        guard !trimmedNewBranchName.isEmpty else { return false }
        return branches.contains {
            $0.kind == .local && $0.localBranchName == trimmedNewBranchName
        }
    }

    private var canCreate: Bool {
        guard let selectedBranch else { return false }
        switch branchMode {
        case .existing:
            return !selectedBranch.isCheckedOut
        case .new:
            return !trimmedNewBranchName.isEmpty && !newBranchAlreadyExists
        }
    }

    private func branchRow(_ branch: GitBranch) -> some View {
        HStack(spacing: 10) {
            Image(systemName: branch.kind == .local ? "arrow.triangle.branch" : "network")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(branch.displayName)
                    .lineLimit(1)
                if branchMode == .existing, branch.kind == .remote {
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
        .opacity(branchMode == .existing && branch.isCheckedOut ? 0.55 : 1)
        .allowsHitTesting(branchMode == .new || !branch.isCheckedOut)
    }

    private func loadBranches() async {
        isLoading = true
        branches = await model.loadBranches(repositoryID: repositoryID)
        isLoading = false
        if selectedBranch == nil
            || (branchMode == .existing && selectedBranch?.isCheckedOut == true)
        {
            selectFirstAvailableBranch()
        }
    }

    private func selectFirstAvailableBranch() {
        switch branchMode {
        case .existing:
            selectedBranchID = filteredBranches.first(where: { !$0.isCheckedOut })?.id
        case .new:
            let repositoryPath = repository?.repositoryURL
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
            selectedBranchID = filteredBranches.first(where: {
                $0.kind == .local
                    && $0.checkoutPath.map {
                        URL(fileURLWithPath: $0)
                            .standardizedFileURL
                            .resolvingSymlinksInPath()
                            .path
                    } == repositoryPath
            })?.id
                ?? filteredBranches.first(where: { $0.kind == .local })?.id
                ?? filteredBranches.first?.id
        }
    }

    @discardableResult
    private func moveBranchSelection(by offset: Int) -> Bool {
        let selectableBranches = filteredBranches.filter {
            branchMode == .new || !$0.isCheckedOut
        }
        guard !selectableBranches.isEmpty else { return false }

        let nextIndex: Int
        if let selectedBranchID,
           let selectedIndex = selectableBranches.firstIndex(where: { $0.id == selectedBranchID })
        {
            nextIndex = min(max(selectedIndex + offset, 0), selectableBranches.count - 1)
        } else {
            nextIndex = offset < 0 ? selectableBranches.count - 1 : 0
        }

        selectedBranchID = selectableBranches[nextIndex].id
        return true
    }

    private func createWorktree() {
        guard let selectedBranch else { return }
        Task {
            let didCreate: Bool
            switch branchMode {
            case .existing:
                didCreate = await model.createWorktree(
                    repositoryID: repositoryID,
                    branch: selectedBranch
                )
            case .new:
                didCreate = await model.createWorktree(
                    repositoryID: repositoryID,
                    newBranchName: trimmedNewBranchName,
                    startingAt: selectedBranch
                )
            }
            if didCreate {
                dismiss()
            }
        }
    }
}
