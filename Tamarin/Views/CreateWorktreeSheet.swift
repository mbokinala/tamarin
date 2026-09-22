import SwiftUI

private enum WorktreeBranchSelection: Hashable {
    case existing(GitBranch.ID)
    case create
}

struct CreateWorktreeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let repositoryID: UUID

    @State private var branches: [GitBranch] = []
    @State private var searchText = ""
    @State private var selection: WorktreeBranchSelection?
    @State private var isLoading = true
    @State private var hasSetupScript = false

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
                TextField("Search or create a branch", text: $searchText)
                .textFieldStyle(.plain)
                .onSubmit(submitSelection)
                .onChange(of: searchText) {
                    selectDefaultBranchChoice()
                }
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
                } else if filteredBranches.isEmpty && creatableBranchName == nil {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ScrollViewReader { proxy in
                        List {
                            if let branchName = creatableBranchName {
                                let choice = WorktreeBranchSelection.create
                                let isSelected = selection == choice
                                Button {
                                    selection = choice
                                } label: {
                                    createBranchRow(named: branchName, isSelected: isSelected)
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(selectionBackground(isSelected))
                                .id(WorktreeBranchSelection.create)
                            }

                            ForEach(filteredBranches) { branch in
                                let choice = WorktreeBranchSelection.existing(branch.id)
                                let isSelected = selection == choice
                                Button {
                                    selection = choice
                                } label: {
                                    branchRow(branch, isSelected: isSelected)
                                }
                                .buttonStyle(.plain)
                                .disabled(branch.isCheckedOut)
                                .listRowBackground(selectionBackground(isSelected))
                                .id(choice)
                            }
                        }
                        .listStyle(.inset)
                        .padding(.horizontal, 12)
                        .onChange(of: selection) { _, selection in
                            guard let selection else { return }
                            proxy.scrollTo(selection)
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

                    if hasSetupScript {
                        Label(
                            "The setup script will run after Git creates the worktree. Its output will open in a terminal tab.",
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
        let query = trimmedSearchText
        guard !query.isEmpty else { return branches }
        let terms = query.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        return branches.filter { branch in
            let candidate = "\(branch.displayName) \(branch.localBranchName)".lowercased()
            return terms.allSatisfy(candidate.contains)
        }
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var exactlyMatchingBranch: GitBranch? {
        guard !trimmedSearchText.isEmpty else { return nil }
        return branches.first { branch in
            branch.displayName.caseInsensitiveCompare(trimmedSearchText) == .orderedSame
                || branch.localBranchName.caseInsensitiveCompare(trimmedSearchText) == .orderedSame
        }
    }

    private var creatableBranchName: String? {
        guard !trimmedSearchText.isEmpty, exactlyMatchingBranch == nil else { return nil }
        return trimmedSearchText
    }

    private var defaultStartPoint: GitBranch? {
        let repositoryPath = repository?.repositoryURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return branches.first(where: {
            $0.kind == .local
                && $0.checkoutPath.map {
                    URL(fileURLWithPath: $0)
                        .standardizedFileURL
                        .resolvingSymlinksInPath()
                        .path
                } == repositoryPath
        })
            ?? branches.first(where: { $0.kind == .local })
            ?? branches.first
    }

    private var canCreate: Bool {
        switch selection {
        case let .existing(branchID):
            return branches.first(where: { $0.id == branchID })?.isCheckedOut == false
        case .create:
            return creatableBranchName != nil && defaultStartPoint != nil
        case nil:
            return false
        }
    }

    private func branchRow(_ branch: GitBranch, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: branch.kind == .local ? "arrow.triangle.branch" : "network")
                .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(branch.displayName)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
                if branch.kind == .remote {
                    Text("Creates local branch \(branch.localBranchName)")
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                } else if let checkoutPath = branch.checkoutPath {
                    Text("Checked out at \(checkoutPath)")
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()
            Text(branch.kind == .local ? "Local" : "Remote")
                .font(.caption2.weight(.medium))
                .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    isSelected ? Color.white.opacity(0.18) : Color.secondary.opacity(0.12),
                    in: Capsule()
                )
            if branch.isCheckedOut {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                    .help("Already checked out")
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(branch.isCheckedOut ? 0.55 : 1)
    }

    private func createBranchRow(named branchName: String, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text("Create branch '\(branchName)'")
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
                if let defaultStartPoint {
                    Text("Starts from \(defaultStartPoint.displayName)")
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                }
            }

            Spacer()
            Text("New")
                .font(.caption2.weight(.medium))
                .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    isSelected ? Color.white.opacity(0.18) : Color.secondary.opacity(0.12),
                    in: Capsule()
                )
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectionBackground(_ isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? Color.accentColor : Color.clear)
    }

    private func loadBranches() async {
        isLoading = true
        if let repository,
           let configuration = try? model.lifecycleConfiguration(for: repository)
        {
            hasSetupScript = configuration.setupScript != nil
        } else {
            hasSetupScript = false
        }
        branches = await model.loadBranches(repositoryID: repositoryID)
        isLoading = false
        selectDefaultBranchChoice()
    }

    private func selectDefaultBranchChoice() {
        if let exactlyMatchingBranch {
            selection = exactlyMatchingBranch.isCheckedOut
                ? nil
                : .existing(exactlyMatchingBranch.id)
        } else if creatableBranchName != nil, defaultStartPoint != nil {
            selection = .create
        } else if let branch = filteredBranches.first(where: { !$0.isCheckedOut }) {
            selection = .existing(branch.id)
        } else {
            selection = nil
        }
    }

    private var selectableBranchChoices: [WorktreeBranchSelection] {
        var choices: [WorktreeBranchSelection] = []
        if creatableBranchName != nil, defaultStartPoint != nil {
            choices.append(.create)
        }
        choices += filteredBranches
            .filter { !$0.isCheckedOut }
            .map { WorktreeBranchSelection.existing($0.id) }
        return choices
    }

    @discardableResult
    private func moveBranchSelection(by offset: Int) -> Bool {
        let choices = selectableBranchChoices
        guard !choices.isEmpty else { return false }

        let nextIndex: Int
        if let selection,
           let selectedIndex = choices.firstIndex(of: selection)
        {
            nextIndex = min(max(selectedIndex + offset, 0), choices.count - 1)
        } else {
            nextIndex = offset < 0 ? choices.count - 1 : 0
        }

        selection = choices[nextIndex]
        return true
    }

    private func submitSelection() {
        guard model.busyMessage == nil else { return }
        if !canCreate {
            selectDefaultBranchChoice()
        }
        guard canCreate else { return }
        createWorktree()
    }

    private func createWorktree() {
        guard canCreate, model.busyMessage == nil else { return }

        switch selection {
        case let .existing(branchID):
            guard let branch = branches.first(where: { $0.id == branchID }) else { return }
            dismiss()
            Task {
                await model.createWorktree(
                    repositoryID: repositoryID,
                    branch: branch
                )
            }
        case .create:
            guard let branchName = creatableBranchName,
                  let startPoint = defaultStartPoint
            else { return }
            dismiss()
            Task {
                await model.createWorktree(
                    repositoryID: repositoryID,
                    newBranchName: branchName,
                    startingAt: startPoint
                )
            }
        case nil:
            return
        }
    }
}
