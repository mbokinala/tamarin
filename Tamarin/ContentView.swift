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
            .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 420)
            .anchorPreference(
                key: SidebarBoundsPreferenceKey.self,
                value: .bounds,
                transform: { $0 }
            )
        } detail: {
            WorktreeWorkspaceView(addRepository: chooseRepository)
        }
        .overlayPreferenceValue(SidebarBoundsPreferenceKey.self) { sidebarBounds in
            GeometryReader { proxy in
                if let sidebarBounds {
                    let frame = proxy[sidebarBounds]
                    sidebarSeam(height: max(frame.height - 10, 0))
                        .position(
                            x: frame.maxX,
                            y: frame.midY + 5
                        )
                }
            }
            .allowsHitTesting(false)
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
    }

    private func sidebarSeam(height: CGFloat) -> some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(
                    color: Color(nsColor: .windowBackgroundColor).opacity(0.72),
                    location: 0.32
                ),
                .init(color: Color(nsColor: .windowBackgroundColor), location: 0.5),
                .init(
                    color: Color(nsColor: .windowBackgroundColor).opacity(0.72),
                    location: 0.68
                ),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: 18, height: height)
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

private struct SidebarBoundsPreferenceKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?

    static func reduce(
        value: inout Anchor<CGRect>?,
        nextValue: () -> Anchor<CGRect>?
    ) {
        value = nextValue() ?? value
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
        .frame(width: 1180, height: 760)
}
