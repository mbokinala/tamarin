//
//  TamarinApp.swift
//  Tamarin
//
//  Created by Manav Bokinala on 8/27/26.
//

import AppKit
import SwiftUI

@MainActor
final class TamarinAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        let alert = NSAlert()
        alert.messageText = "Quit Tamarin?"
        alert.informativeText = "Any open terminal sessions will close."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        return alert.runModal() == .alertFirstButtonReturn
            ? .terminateNow
            : .terminateCancel
    }
}

@main
struct TamarinApp: App {
    @NSApplicationDelegateAdaptor(TamarinAppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1220, height: 780)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandMenu("Worktree") {
                Button("Previous Worktree") {
                    _ = model.selectPreviousWorktree()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(!model.canSelectPreviousWorktree)

                Button("Next Worktree") {
                    _ = model.selectNextWorktree()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(!model.canSelectNextWorktree)
            }

            CommandMenu("Terminal") {
                Button("New Terminal") {
                    _ = model.createTerminal()
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!model.canCreateTerminal)

                Button("Close Terminal") {
                    _ = model.closeActiveTerminal()
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(!model.canCloseActiveTerminal)
            }
        }
    }
}
