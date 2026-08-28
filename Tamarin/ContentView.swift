//
//  ContentView.swift
//  Tamarin
//
//  Created by Manav Bokinala on 8/27/26.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var worktreeRepository: RepositoryRecord?
    @State private var settingsRepository: RepositoryRecord?

    var body: some View {
        @Bindable var model = model

        NavigationSplitView(columnVisibility: $columnVisibility) {
            RepositorySidebar(
                addRepository: chooseRepository,
                createWorktree: { worktreeRepository = $0 },
                showSettings: { settingsRepository = $0 }
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 380)
        } detail: {
            WorktreeWorkspaceView(addRepository: chooseRepository)
        }
        .task {
            await model.start()
        }
        .sheet(item: $worktreeRepository) { repository in
            CreateWorktreeSheet(repositoryID: repository.id)
                .environment(model)
        }
        .sheet(item: $settingsRepository) { repository in
            RepositorySettingsSheet(repository: repository)
                .environment(model)
        }
        .alert(item: $model.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .overlay(alignment: .top) {
            if let busyMessage = model.busyMessage {
                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                    Text(busyMessage)
                        .font(.callout.weight(.medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .padding(.top, 12)
                .allowsHitTesting(false)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: chooseRepository) {
                    Label("Add Repository", systemImage: "folder.badge.plus")
                }
                .help("Add a Git repository")
            }
        }
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.title = "Add Git Repository"
        panel.message = "Choose a repository folder or any folder inside one."
        panel.prompt = "Add Repository"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                await model.addRepository(at: url)
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
        .frame(width: 1180, height: 760)
}
