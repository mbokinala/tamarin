import AppKit
import SwiftUI

struct RepositorySettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let repository: RepositoryRecord

    @State private var name: String
    @State private var worktreeRoot: String
    @State private var setupScript: String
    @State private var teardownScript: String
    @State private var isLoadingConfiguration = true
    @State private var configurationLoadError: String?
    @State private var showingForgetConfirmation = false

    init(repository: RepositoryRecord) {
        self.repository = repository
        _name = State(initialValue: repository.name)
        _worktreeRoot = State(initialValue: repository.worktreeRoot ?? "")
        _setupScript = State(initialValue: repository.setupScript ?? "")
        _teardownScript = State(initialValue: "")
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

                Section("Lifecycle Scripts") {
                    LabeledContent("Configuration file") {
                        Text(model.configurationFileURL(for: repository).path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(model.configurationFileURL(for: repository).path)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Available environment variables")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("$TAMARIN_REPO_DIR   $TAMARIN_WORKTREE_DIR")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }

                    if isLoadingConfiguration {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading configuration…")
                                .foregroundStyle(.secondary)
                        }
                    } else if let configurationLoadError {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(configurationLoadError, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Button("Try Again", action: loadConfiguration)
                        }
                        .font(.caption)
                    }
                }

                Section {
                    TextEditor(text: $setupScript)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        .disabled(isLoadingConfiguration || configurationLoadError != nil)
                } header: {
                    Text("Setup Script")
                } footer: {
                    Text("Runs with zsh after Tamarin creates a worktree. The working directory is the new worktree.")
                }

                Section {
                    TextEditor(text: $teardownScript)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        .disabled(isLoadingConfiguration || configurationLoadError != nil)
                } header: {
                    Text("Teardown Script")
                } footer: {
                    Text("Runs with zsh before Tamarin removes a worktree. If it fails, the worktree is kept. Scripts run as trusted, non-interactive code with your user permissions.")
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
                    if model.updateRepository(
                        id: repository.id,
                        name: name,
                        worktreeRoot: worktreeRoot,
                        setupScript: setupScript,
                        teardownScript: teardownScript
                    ) {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isLoadingConfiguration || configurationLoadError != nil)
            }
            .padding(16)
        }
        .frame(minWidth: 700, minHeight: 780)
        .task(id: repository.id) {
            loadConfiguration()
        }
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

    private func loadConfiguration() {
        isLoadingConfiguration = true
        do {
            let configuration = try model.lifecycleConfiguration(for: repository)
            setupScript = configuration.setupScript ?? ""
            teardownScript = configuration.teardownScript ?? ""
            configurationLoadError = nil
        } catch {
            configurationLoadError = error.localizedDescription
        }
        isLoadingConfiguration = false
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
