import Foundation

public nonisolated enum RepositoryConfigurationError: LocalizedError, Sendable {
    case unreadable(path: String, detail: String)
    case invalid(path: String, line: Int, detail: String)
    case unwritable(path: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(path, detail):
            return "Could not read \(path). \(detail)"
        case let .invalid(path, line, detail):
            return "The Tamarin configuration at \(path) is invalid on line \(line). \(detail)"
        case let .unwritable(path, detail):
            return "Could not write \(path). \(detail)"
        }
    }
}

/// Reads and writes the repository-owned `.tamarin/config.toml` file.
///
/// Tamarin deliberately owns a small TOML surface: `setup` and `teardown`
/// strings in the `[scripts]` table. Keeping the format narrow avoids adding a
/// package dependency to the app while still producing ordinary, editable TOML.
public nonisolated struct RepositoryConfigurationStore: Sendable {
    public static let relativePath = ".tamarin/config.toml"

    public init() {}

    public func fileURL(in repositoryDirectory: URL) -> URL {
        repositoryDirectory
            .appending(path: ".tamarin", directoryHint: .isDirectory)
            .appending(path: "config.toml", directoryHint: .notDirectory)
    }

    /// Returns `nil` when the repository does not have a configuration file.
    public func load(
        from repositoryDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> RepositoryLifecycleConfiguration? {
        let url = fileURL(in: repositoryDirectory)
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw RepositoryConfigurationError.unreadable(
                path: url.path,
                detail: error.localizedDescription
            )
        }
        guard let source = String(data: data, encoding: .utf8) else {
            throw RepositoryConfigurationError.unreadable(
                path: url.path,
                detail: "The file is not valid UTF-8."
            )
        }

        return try Self.parse(source, path: url.path)
    }

    public func save(
        _ configuration: RepositoryLifecycleConfiguration,
        in repositoryDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        let url = fileURL(in: repositoryDirectory)
        let directory = url.deletingLastPathComponent()

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
            try Data(Self.serialize(configuration).utf8).write(to: url, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: url.path
            )
        } catch {
            throw RepositoryConfigurationError.unwritable(
                path: url.path,
                detail: error.localizedDescription
            )
        }
    }

    static func serialize(_ configuration: RepositoryLifecycleConfiguration) -> String {
        var source = """
        # Repository settings used by Tamarin.
        # Scripts run with TAMARIN_REPO_DIR and TAMARIN_WORKTREE_DIR in the environment.

        [scripts]
        """

        if let setup = configuration.setupScript {
            source += "\n" + encoded(script: setup, key: "setup")
        }
        if let teardown = configuration.teardownScript {
            source += "\n" + encoded(script: teardown, key: "teardown")
        }
        return source + "\n"
    }

    private static func encoded(script: String, key: String) -> String {
        let canUseLiteralString = !script.contains("'''")
            && script.unicodeScalars.allSatisfy {
                ($0.value >= 0x20 && $0.value != 0x7F) || $0 == "\t" || $0 == "\n"
            }
        if canUseLiteralString {
            // TOML removes the first newline after a multiline delimiter. The
            // closing delimiter is appended directly so the script's own final
            // newline, when present, is preserved exactly.
            return "\(key) = '''\n\(script)'''"
        }

        var escaped = ""
        for scalar in script.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\u{08}": escaped += "\\b"
            case "\t": escaped += "\\t"
            case "\n": escaped += "\n"
            case "\u{0C}": escaped += "\\f"
            case "\r": escaped += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    escaped += String(format: "\\u%04X", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return "\(key) = \"\"\"\n\(escaped)\"\"\""
    }

    private static func parse(
        _ source: String,
        path: String
    ) throws -> RepositoryLifecycleConfiguration {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var section = ""
        var setup: String?
        var teardown: String?
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                index += 1
                continue
            }

            if trimmed.hasPrefix("[") {
                guard let closingBracket = trimmed.firstIndex(of: "]") else {
                    throw invalid(path, line: index, "A table header is missing its closing bracket.")
                }
                let trailing = trimmed[trimmed.index(after: closingBracket)...]
                    .trimmingCharacters(in: .whitespaces)
                guard trailing.isEmpty || trailing.hasPrefix("#") else {
                    throw invalid(path, line: index, "Unexpected text follows the table header.")
                }
                section = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closingBracket])
                    .trimmingCharacters(in: .whitespaces)
                index += 1
                continue
            }

            // Other tables are reserved for future repository settings. Ignore
            // their scalar lines rather than preventing newer config files from
            // opening in an older Tamarin release.
            guard section == "scripts" else {
                index += 1
                continue
            }

            guard let equals = line.firstIndex(of: "=") else {
                throw invalid(path, line: index, "Expected a key/value assignment.")
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard key == "setup" || key == "teardown" else {
                throw invalid(path, line: index, "The [scripts] table supports only setup and teardown.")
            }
            var valueText = String(line[line.index(after: equals)...])
                .trimmingCharacters(in: .whitespaces)
            let value: String

            if valueText.hasPrefix("'''") || valueText.hasPrefix("\"\"\"") {
                let delimiter = valueText.hasPrefix("'''") ? "'''" : "\"\"\""
                let isBasic = delimiter == "\"\"\""
                valueText.removeFirst(3)
                let parsed = try parseMultilineString(
                    initialText: valueText,
                    delimiter: delimiter,
                    isBasic: isBasic,
                    lines: lines,
                    lineIndex: &index,
                    path: path
                )
                value = parsed
            } else if valueText.hasPrefix("\"") || valueText.hasPrefix("'") {
                value = try parseSingleLineString(valueText, line: index, path: path)
            } else {
                throw invalid(path, line: index, "Script values must be TOML strings.")
            }

            if key == "setup" {
                guard setup == nil else {
                    throw invalid(path, line: index, "The setup key is defined more than once.")
                }
                setup = value
            } else {
                guard teardown == nil else {
                    throw invalid(path, line: index, "The teardown key is defined more than once.")
                }
                teardown = value
            }
            index += 1
        }

        return RepositoryLifecycleConfiguration(
            setupScript: setup,
            teardownScript: teardown
        )
    }

    private static func parseMultilineString(
        initialText: String,
        delimiter: String,
        isBasic: Bool,
        lines: [String],
        lineIndex: inout Int,
        path: String
    ) throws -> String {
        var pieces: [String] = []
        var current = initialText
        var isFirstPiece = true

        while true {
            if let closing = closingDelimiterRange(in: current, delimiter: delimiter, isBasic: isBasic) {
                let content = String(current[..<closing.lowerBound])
                if !(isFirstPiece && content.isEmpty) {
                    pieces.append(content)
                }
                let remainder = current[closing.upperBound...]
                    .trimmingCharacters(in: .whitespaces)
                guard remainder.isEmpty || remainder.hasPrefix("#") else {
                    throw invalid(path, line: lineIndex, "Unexpected text follows the script string.")
                }
                let joined = pieces.joined(separator: "\n")
                return isBasic
                    ? try decodeBasicString(joined, line: lineIndex, path: path)
                    : joined
            }

            // TOML trims exactly one newline immediately after a multiline
            // opening delimiter.
            if !(isFirstPiece && current.isEmpty) {
                pieces.append(current)
            }
            isFirstPiece = false
            lineIndex += 1
            guard lineIndex < lines.count else {
                throw invalid(path, line: max(0, lineIndex - 1), "The script string is not terminated.")
            }
            current = lines[lineIndex]
        }
    }

    private static func closingDelimiterRange(
        in text: String,
        delimiter: String,
        isBasic: Bool
    ) -> Range<String.Index>? {
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: delimiter, range: searchStart..<text.endIndex)
        {
            guard isBasic else { return range }
            var slashCount = 0
            var cursor = range.lowerBound
            while cursor > text.startIndex {
                let previous = text.index(before: cursor)
                guard text[previous] == "\\" else { break }
                slashCount += 1
                cursor = previous
            }
            if slashCount.isMultiple(of: 2) { return range }
            // A valid delimiter can overlap an escaped quote followed by the
            // three closing quotes (for example: \\"\"\"\"). Advance one
            // character so that overlapping candidates are considered.
            searchStart = text.index(after: range.lowerBound)
        }
        return nil
    }

    private static func parseSingleLineString(
        _ text: String,
        line: Int,
        path: String
    ) throws -> String {
        let quote = text.first!
        var cursor = text.index(after: text.startIndex)
        var raw = ""
        var escaped = false

        while cursor < text.endIndex {
            let character = text[cursor]
            if quote == "\"", character == "\\", !escaped {
                escaped = true
                raw.append(character)
                cursor = text.index(after: cursor)
                continue
            }
            if character == quote, !escaped {
                let remainder = text[text.index(after: cursor)...]
                    .trimmingCharacters(in: .whitespaces)
                guard remainder.isEmpty || remainder.hasPrefix("#") else {
                    throw invalid(path, line: line, "Unexpected text follows the script string.")
                }
                return quote == "\""
                    ? try decodeBasicString(raw, line: line, path: path)
                    : raw
            }
            raw.append(character)
            escaped = false
            cursor = text.index(after: cursor)
        }
        throw invalid(path, line: line, "The script string is not terminated.")
    }

    private static func decodeBasicString(
        _ value: String,
        line: Int,
        path: String
    ) throws -> String {
        var result = ""
        var cursor = value.startIndex

        while cursor < value.endIndex {
            let character = value[cursor]
            guard character == "\\" else {
                result.append(character)
                cursor = value.index(after: cursor)
                continue
            }

            let escapeIndex = value.index(after: cursor)
            guard escapeIndex < value.endIndex else {
                throw invalid(path, line: line, "A script string ends with an incomplete escape.")
            }
            let escape = value[escapeIndex]
            switch escape {
            case "b": result.append("\u{08}")
            case "t": result.append("\t")
            case "n": result.append("\n")
            case "f": result.append("\u{0C}")
            case "r": result.append("\r")
            case "\"": result.append("\"")
            case "\\": result.append("\\")
            case "\n":
                // In a TOML multiline basic string, a trailing backslash folds
                // the newline and all following indentation/blank lines.
                cursor = value.index(after: escapeIndex)
                while cursor < value.endIndex,
                      value[cursor] == " " || value[cursor] == "\t" || value[cursor] == "\n"
                {
                    cursor = value.index(after: cursor)
                }
                continue
            case "u", "U":
                let digitCount = escape == "u" ? 4 : 8
                let digitsStart = value.index(after: escapeIndex)
                guard let digitsEnd = value.index(
                    digitsStart,
                    offsetBy: digitCount,
                    limitedBy: value.endIndex
                ) else {
                    throw invalid(path, line: line, "A Unicode escape is incomplete.")
                }
                let digits = value[digitsStart..<digitsEnd]
                guard let number = UInt32(digits, radix: 16),
                      let scalar = UnicodeScalar(number),
                      !(0xD800...0xDFFF).contains(number)
                else {
                    throw invalid(path, line: line, "A Unicode escape is invalid.")
                }
                result.unicodeScalars.append(scalar)
                cursor = digitsEnd
                continue
            default:
                throw invalid(path, line: line, "The escape \\\(escape) is not supported by TOML.")
            }
            cursor = value.index(after: escapeIndex)
        }
        return result
    }

    private static func invalid(
        _ path: String,
        line: Int,
        _ detail: String
    ) -> RepositoryConfigurationError {
        .invalid(path: path, line: line + 1, detail: detail)
    }
}
