import Darwin
import Foundation

private nonisolated final class ProcessCaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutResult: Result<Data, Error>?
    private var stderrResult: Result<Data, Error>?
    private var terminationStatus: Int32?

    func setStdout(_ result: Result<Data, Error>) {
        lock.lock()
        stdoutResult = result
        lock.unlock()
    }

    func setStderr(_ result: Result<Data, Error>) {
        lock.lock()
        stderrResult = result
        lock.unlock()
    }

    func setTerminationStatus(_ status: Int32) {
        lock.lock()
        terminationStatus = status
        lock.unlock()
    }

    func capturedValues() throws -> (stdout: Data, stderr: Data, status: Int32) {
        lock.lock()
        defer { lock.unlock() }

        let stdout = try stdoutResult?.get() ?? Data()
        let stderr = try stderrResult?.get() ?? Data()
        return (stdout, stderr, terminationStatus ?? -1)
    }
}

public nonisolated struct ProcessResult: Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let terminationStatus: Int32
    public let stdoutData: Data
    public let stderrData: Data

    public init(
        executableURL: URL,
        arguments: [String],
        terminationStatus: Int32,
        stdoutData: Data,
        stderrData: Data
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.terminationStatus = terminationStatus
        self.stdoutData = stdoutData
        self.stderrData = stderrData
    }

    public var stdout: String { String(decoding: stdoutData, as: UTF8.self) }
    public var stderr: String { String(decoding: stderrData, as: UTF8.self) }
    public var succeeded: Bool { terminationStatus == 0 }
}

public nonisolated enum ProcessRunnerError: LocalizedError, Sendable {
    case launchFailed(command: String, reason: String)
    case outputReadFailed(command: String, reason: String)
    case nonZeroExit(command: String, status: Int32, output: String)

    public var errorDescription: String? {
        switch self {
        case let .launchFailed(command, reason):
            return "Could not start \(command): \(reason)"
        case let .outputReadFailed(command, reason):
            return "Could not read output from \(command): \(reason)"
        case let .nonZeroExit(command, status, output):
            let detail = output.isEmpty ? "The command did not provide an error message." : output
            return "\(command) exited with status \(status). \(detail)"
        }
    }
}

/// Runs child processes without blocking the caller's actor and drains stdout and
/// stderr concurrently to avoid pipe-buffer deadlocks.
public nonisolated struct ProcessRunner: Sendable {
    public init() {}

    public func run(
        executableURL: URL,
        arguments: [String] = [],
        currentDirectoryURL: URL? = nil,
        environment: [String: String] = [:],
        standardInput: Data? = nil,
        standardOutputHandler: (@Sendable (Data) -> Void)? = nil,
        standardErrorHandler: (@Sendable (Data) -> Void)? = nil
    ) async throws -> ProcessResult {
        try Task.checkCancellation()

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = standardInput == nil ? nil : Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe ?? FileHandle.nullDevice

        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in
                override
            }
        }

        let command = Self.displayCommand(executableURL: executableURL, arguments: arguments)

        do {
            try process.run()
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            try? stdinPipe?.fileHandleForWriting.close()
            throw ProcessRunnerError.launchFailed(command: command, reason: error.localizedDescription)
        }

        // The child owns duplicated write descriptors after launch. Closing the
        // parent's copies is essential: otherwise a reader can wait forever for
        // EOF even after the child process has exited.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        // FileHandle's synchronous reads and Process.waitUntilExit() are blocking
        // APIs. Run them on dedicated background threads, not Swift's cooperative
        // task pool, and drain both pipes concurrently to prevent pipe-buffer
        // deadlocks and task-pool starvation.
        let captureState = ProcessCaptureState()
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .utility)

        group.enter()
        Thread.detachNewThread {
            autoreleasepool {
                defer { group.leave() }
                captureState.setStdout(
                    Result {
                        try Self.readAll(
                            from: stdoutPipe.fileHandleForReading,
                            onChunk: standardOutputHandler
                        )
                    }
                )
                try? stdoutPipe.fileHandleForReading.close()
            }
        }

        group.enter()
        Thread.detachNewThread {
            autoreleasepool {
                defer { group.leave() }
                captureState.setStderr(
                    Result {
                        try Self.readAll(
                            from: stderrPipe.fileHandleForReading,
                            onChunk: standardErrorHandler
                        )
                    }
                )
                try? stderrPipe.fileHandleForReading.close()
            }
        }

        if let standardInput, let inputHandle = stdinPipe?.fileHandleForWriting {
            group.enter()
            Thread.detachNewThread {
                autoreleasepool {
                    defer { group.leave() }
                    try? inputHandle.write(contentsOf: standardInput)
                    try? inputHandle.close()
                }
            }
        }

        group.enter()
        Thread.detachNewThread {
            autoreleasepool {
                defer { group.leave() }
                process.waitUntilExit()
                captureState.setTerminationStatus(process.terminationStatus)
            }
        }

        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                group.notify(queue: queue) {
                    do {
                        let capture = try captureState.capturedValues()
                        continuation.resume(
                            returning: ProcessResult(
                                executableURL: executableURL,
                                arguments: arguments,
                                terminationStatus: capture.status,
                                stdoutData: capture.stdout,
                                stderrData: capture.stderr
                            )
                        )
                    } catch {
                        continuation.resume(
                            throwing: ProcessRunnerError.outputReadFailed(
                                command: command,
                                reason: error.localizedDescription
                            )
                        )
                    }
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
            try? stdinPipe?.fileHandleForWriting.close()
        }
        try Task.checkCancellation()
        return result
    }

    public func runChecked(
        executableURL: URL,
        arguments: [String] = [],
        currentDirectoryURL: URL? = nil,
        environment: [String: String] = [:],
        standardInput: Data? = nil,
        standardOutputHandler: (@Sendable (Data) -> Void)? = nil,
        standardErrorHandler: (@Sendable (Data) -> Void)? = nil
    ) async throws -> ProcessResult {
        let result = try await run(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL,
            environment: environment,
            standardInput: standardInput,
            standardOutputHandler: standardOutputHandler,
            standardErrorHandler: standardErrorHandler
        )

        guard result.succeeded else {
            let detail = Self.preferredErrorOutput(from: result)
            throw ProcessRunnerError.nonZeroExit(
                command: Self.displayCommand(executableURL: executableURL, arguments: arguments),
                status: result.terminationStatus,
                output: detail
            )
        }

        return result
    }

    private static func readAll(
        from handle: FileHandle,
        onChunk: (@Sendable (Data) -> Void)?
    ) throws -> Data {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        let descriptor = handle.fileDescriptor

        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if bytesRead == 0 { break }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }

            let chunk = Data(buffer.prefix(bytesRead))
            output.append(chunk)
            onChunk?(chunk)
        }
        return output
    }

    private static func preferredErrorOutput(from result: ProcessResult) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func displayCommand(executableURL: URL, arguments: [String]) -> String {
        ([executableURL.path] + arguments)
            .map(Self.shellQuotedForDisplay)
            .joined(separator: " ")
    }

    private static func shellQuotedForDisplay(_ value: String) -> String {
        let safeCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=@"))
        if !value.isEmpty, value.unicodeScalars.allSatisfy(safeCharacters.contains) {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
