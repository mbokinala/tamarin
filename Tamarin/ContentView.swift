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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSidebarVisible = true
    @State private var sidebarWidth: CGFloat = 300
    @State private var sidebarDragStartWidth: CGFloat?
    @State private var worktreeRepository: RepositoryRecord?
    @State private var settingsRepository: RepositoryRecord?

    private let sidebarMinimumWidth: CGFloat = 250
    private let sidebarMaximumWidth: CGFloat = 420

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 0) {
            RepositorySidebar(
                addRepository: chooseRepository,
                createWorktree: { worktreeRepository = $0 },
                showSettings: { settingsRepository = $0 }
            )
            .frame(width: sidebarWidth)
            .background(.regularMaterial)
            .frame(
                width: isSidebarVisible ? sidebarWidth : 0,
                alignment: .trailing
            )
            .clipped()
            .allowsHitTesting(isSidebarVisible)
            .accessibilityHidden(!isSidebarVisible)

            sidebarDivider
                .frame(width: isSidebarVisible ? 1 : 0)
                .opacity(isSidebarVisible ? 1 : 0)
                .allowsHitTesting(isSidebarVisible)

            WorktreeWorkspaceView(
                addRepository: chooseRepository,
                isSidebarVisible: isSidebarVisible,
                toggleSidebar: toggleSidebar
            )
            .frame(minWidth: 0, maxWidth: .infinity)
            .layoutPriority(1)
            .ignoresSafeArea(.container, edges: .top)
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

    private var sidebarDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .overlay {
                Color.clear
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(
                            minimumDistance: 0,
                            coordinateSpace: .global
                        )
                        .onChanged { value in
                            if sidebarDragStartWidth == nil {
                                sidebarDragStartWidth = sidebarWidth
                            }

                            let proposedWidth =
                                (sidebarDragStartWidth ?? sidebarWidth)
                                + value.translation.width
                            sidebarWidth = min(
                                max(proposedWidth, sidebarMinimumWidth),
                                sidebarMaximumWidth
                            )
                        }
                        .onEnded { _ in
                            sidebarDragStartWidth = nil
                        }
                    )
            }
    }

    private func toggleSidebar() {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
            isSidebarVisible.toggle()
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
