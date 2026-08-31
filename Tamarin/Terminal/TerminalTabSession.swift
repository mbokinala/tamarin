import Combine
import Foundation
import GhosttyTerminal
import Observation

enum TerminalTabKind: Equatable {
    case shell
    case setupOutput

    func defaultTitle(ordinal: Int) -> String {
        switch self {
        case .shell: "Terminal \(ordinal)"
        case .setupOutput: "Setup Output"
        }
    }
}

/// Thread-safe bridge from process pipe chunks into an in-memory Ghostty
/// session. It also converts pipe-style LF line endings into terminal CRLF.
nonisolated final class SetupOutputSession: @unchecked Sendable {
    let terminalSession: InMemoryTerminalSession

    private let lock = NSLock()
    private var previousByte: UInt8?

    init() {
        terminalSession = InMemoryTerminalSession(
            write: { _ in },
            resize: { _ in }
        )
    }

    func receive(_ string: String) {
        receive(Data(string.utf8))
    }

    func receive(_ data: Data) {
        guard !data.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        var converted = Data()
        converted.reserveCapacity(data.count + data.count / 20)
        for byte in data {
            if byte == 0x0A, previousByte != 0x0D {
                converted.append(0x0D)
            }
            converted.append(byte)
            previousByte = byte
        }
        terminalSession.receive(converted)
    }
}

@MainActor
@Observable
final class TerminalTabSession: Identifiable {
    let id: UUID
    let repositoryID: UUID
    let worktreePath: String
    let ordinal: Int
    let kind: TerminalTabKind

    var customTitle: String?
    var generatedTitle: String
    var isExited = false
    var exitedWithProcessAlive = false

    @ObservationIgnored let terminal: TerminalViewState
    @ObservationIgnored private let setupOutputSession: SetupOutputSession?
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []

    init(
        id: UUID = UUID(),
        repositoryID: UUID,
        worktreePath: String,
        ordinal: Int,
        customTitle: String? = nil,
        kind: TerminalTabKind = .shell,
        setupOutputSession: SetupOutputSession? = nil
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.worktreePath = worktreePath
        self.ordinal = ordinal
        self.kind = kind
        self.customTitle = customTitle
        generatedTitle = kind.defaultTitle(ordinal: ordinal)

        let outputSession: SetupOutputSession?
        let backend: TerminalSessionBackend
        switch kind {
        case .shell:
            outputSession = nil
            backend = .exec
        case .setupOutput:
            let session = setupOutputSession ?? SetupOutputSession()
            outputSession = session
            backend = .inMemory(session.terminalSession)
        }
        self.setupOutputSession = outputSession

        let terminal = TerminalViewState(
            terminalConfiguration: TerminalConfiguration()
                .windowPaddingX(10)
                .windowPaddingY(8)
                .custom("keybind", "super+t=unbind")
                .custom("keybind", "super+w=unbind")
                .custom("keybind", "super+q=unbind")
                .custom("keybind", "super+shift+left_bracket=unbind")
                .custom("keybind", "super+shift+right_bracket=unbind")
        )
        terminal.configuration = TerminalSurfaceOptions(
            backend: backend,
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

    var tabTitle: String {
        if let customTitle, !customTitle.isEmpty {
            return customTitle
        }
        return kind.defaultTitle(ordinal: ordinal)
    }

    var isSetupOutput: Bool {
        kind == .setupOutput
    }

    func rename(to title: String) {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        customTitle = cleaned.isEmpty ? nil : cleaned
    }
}
