import Combine
import Foundation
import GhosttyTerminal
import Observation

@MainActor
@Observable
final class TerminalTabSession: Identifiable {
    let id: UUID
    let repositoryID: UUID
    let worktreePath: String
    let ordinal: Int

    var customTitle: String?
    var generatedTitle: String
    var isExited = false
    var exitedWithProcessAlive = false

    @ObservationIgnored let terminal: TerminalViewState
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []

    init(
        id: UUID = UUID(),
        repositoryID: UUID,
        worktreePath: String,
        ordinal: Int,
        customTitle: String? = nil
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.worktreePath = worktreePath
        self.ordinal = ordinal
        self.customTitle = customTitle
        generatedTitle = "Terminal \(ordinal)"

        let terminal = TerminalViewState()
        terminal.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: worktreePath,
            envVars: [
                "TAMARIN_TERMINAL_ID": id.uuidString,
                "TAMARIN_WORKTREE": worktreePath,
            ]
        )
        self.terminal = terminal

        terminal.$title
            .removeDuplicates()
            .sink { [weak self] title in
                let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { return }
                self?.generatedTitle = cleaned
            }
            .store(in: &cancellables)

        terminal.onClose = { [weak self] processAlive in
            self?.isExited = true
            self?.exitedWithProcessAlive = processAlive
        }
    }

    var title: String {
        if let customTitle, !customTitle.isEmpty {
            return customTitle
        }
        return generatedTitle
    }

    func rename(to title: String) {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        customTitle = cleaned.isEmpty ? nil : cleaned
    }
}
