import AppKit
import SwiftUI

struct RepositorySettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let repository: RepositoryRecord

    @State private var name: String
    @State private var worktreeRoot: String
    @State private var setupScript: String
    @State private var showingForgetConfirmation = false

    init(repository: RepositoryRecord) {
        self.repository = repository
        _name = State(initialValue: repository.name)
        _worktreeRoot = State(initialValue: repository.worktreeRoot ?? "")
        _setupScript = State(initialValue: repository.setupScript ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Repository Settings")
                        .font(.title2.weight(.semibold))
                    Text(repository.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            Form {
                Section("Repository") {
                    TextField("Display name", text: $name)
                    LabeledContent("Repository path") {
                        Text(repository.path)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Section {
                    HStack {
                        TextField(
                            model.defaultWorktreeRoot(for: repository).path,
                            text: $worktreeRoot
                        )
                        Button("Choose…", action: chooseWorktreeRoot)
                        if !worktreeRoot.isEmpty {
                            Button("Use Default") { worktreeRoot = "" }
                        }
                    }
                } header: {
                    Text("Worktree Directory")
                } footer: {
                    Text("New worktrees use Tamarin's central Application Support directory unless you set a repository-specific directory here.")
                }

                Section {
                    TextEditor(text: $setupScript)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 170)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                } header: {
                    Text("Setup Script")
                } footer: {
                    Text("Runs once with zsh in every worktree created by Tamarin. This is trusted code with your user permissions; keep it non-interactive.")
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Forget Repository…", role: .destructive) {
                    showingForgetConfirmation = true
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.updateRepository(
                        id: repository.id,
                        name: name,
                        worktreeRoot: worktreeRoot,
                        setupScript: setupScript
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 680, minHeight: 640)
        .confirmationDialog(
            "Forget \(repository.name)?",
            isPresented: $showingForgetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Forget Repository", role: .destructive) {
                model.forgetRepository(id: repository.id)
                if model.repository(id: repository.id) == nil {
                    dismiss()
                }
            }
        } message: {
            Text("This removes the repository from Tamarin. It does not delete the repository, its branches, or its worktrees.")
        }
    }

    private func chooseWorktreeRoot() {
        let panel = NSOpenPanel()
        panel.title = "Choose Worktree Directory"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if !worktreeRoot.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: worktreeRoot, isDirectory: true)
        }

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            worktreeRoot = url.standardizedFileURL.path
        }
    }
}
