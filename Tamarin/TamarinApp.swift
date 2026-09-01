//
//  TamarinApp.swift
//  Tamarin
//
//  Created by Manav Bokinala on 8/27/26.
//

import AppKit
import Sparkle
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
    private let updaterController: SPUStandardUpdaterController?

    init() {
        guard
            let encodedPublicKey = Bundle.main.object(
                forInfoDictionaryKey: "SUPublicEDKey"
            ) as? String,
            Data(base64Encoded: encodedPublicKey)?.count == 32
        else {
            updaterController = nil
            return
        }

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 560)
                .background(WindowChromeConfigurator())
        }
        .defaultSize(width: 1220, height: 780)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(after: .appInfo) {
                if let updaterController {
                    CheckForUpdatesView(updater: updaterController.updater)
                }
            }

            CommandMenu("Worktree") {
                Button("New Worktree…") {
                    _ = model.requestWorktreeCreation()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!model.canCreateWorktree)

                Divider()

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

private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(nsView.window)
        }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbar?.showsBaselineSeparator = false
    }
}
