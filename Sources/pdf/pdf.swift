import ArgumentParser
import Foundation
import PDFKit

@main
struct PDF: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pdf",
        abstract: "macOS terminal PDF reader for LLM agents.",
        discussion: "Stream page text or keyword-matched lines from PDFs with predictable, page-delimited output.",
        subcommands: [Text.self, Search.self, Completions.self],
        defaultSubcommand: Text.self
    )
}

// MARK: - Subcommands

extension PDF {
    struct Text: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Emit page text for all or selected pages.")

        @Argument(help: "Path to the PDF file.")
        var file: String

        @Option(name: [.short, .long], help: "Pages to include (comma and ranges allowed, e.g. 1,4-6).")
        var pages: String?

        @Flag(name: [.long], inversion: .prefixedNo, help: "Show a header before each page.")
        var headers: Bool = true

        @Flag(name: [.long], help: "Print the total page count before content.")
        var showCount: Bool = false

        func run() throws {
            let document = try PDFLoader.open(path: file)
            let pageNumbers = try PageSelector(rawValue: pages, pageCount: document.pageCount).pageNumbers

            if showCount {
                print("pageCount=\(document.pageCount)")
            }

            for pageNumber in pageNumbers {
                guard let page = document.page(at: pageNumber - 1), let text = page.string else { continue }
                if headers {
                    print("--- PAGE \(pageNumber) ---")
                }
                print(text)
            }
        }
    }

    struct Search: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Search page text for terms or regex patterns.",
            aliases: ["filter"]
        )

        @Argument(help: "Path to the PDF file.")
        var file: String

        @Option(
            name: [.short, .long],
            parsing: .upToNextOption,
            help: "Search terms or regex patterns. Repeatable or comma-separated."
        )
        var term: [String] = []

        @Option(name: [.long], help: "File containing search terms (newline or comma separated).")
        var termsFile: String?

        @Option(name: [.customShort("p"), .long], help: "Pages to include (comma and ranges allowed).")
        var pages: String?

        @Flag(name: [.long], help: "Treat search terms as regular expressions.")
        var regex: Bool = false

        @Flag(name: [.long], help: "Match with case sensitivity (off by default).")
        var caseSensitive: Bool = false

        @Option(name: [.long], help: "Lines of context before and after each match.")
        var context: Int = 0

        @Option(name: [.long], help: "Output format: text or json.")
        var format: OutputFormat = .text

        @Option(name: [.long], help: "Stop after emitting N matches.")
        var maxMatches: Int?

        @Flag(name: [.long], help: "Omit the built-in default keyword list.")
        var noDefaults: Bool = false

        @Flag(name: [.long], inversion: .prefixedNo, help: "Show a header before each page that has matches.")
        var headers: Bool = true

        func run() throws {
            let document = try PDFLoader.open(path: file)
            let pageNumbers = try PageSelector(rawValue: pages, pageCount: document.pageCount).pageNumbers
            guard context >= 0 else { throw CLIError.invalidContext(context) }

            var keywords = try SearchTermLoader.load(cliTerms: term, termsFile: termsFile)
            if !noDefaults {
                keywords.append(contentsOf: DefaultKeywords.values)
            }
            let uniqueTerms = Array(Set(keywords)).filter { !$0.isEmpty }
            guard !uniqueTerms.isEmpty else { throw CLIError.noKeywords }

            let matcher = try PatternMatcher(keywords: uniqueTerms, regex: regex, caseSensitive: caseSensitive)
            var emitted = 0
            var matches: [Match] = []

            for pageNumber in pageNumbers {
                guard let page = document.page(at: pageNumber - 1), let rawText = page.string else { continue }
                let lines = rawText.split(whereSeparator: \.isNewline).map(String.init)
                var printedHeader = false

                for (idx, lineRaw) in lines.enumerated() {
                    let line = lineRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty else { continue }

                    if matcher.matches(line: line) {
                        let lowerBound = max(0, idx - context)
                        let upperBound = min(lines.count - 1, idx + context)
                        let contextBefore = Array(lines[lowerBound..<idx])
                        let contextAfter = Array(lines[(idx + 1)...upperBound])

                        let matchRecord = Match(
                            page: pageNumber,
                            line: idx + 1,
                            text: line,
                            contextBefore: contextBefore,
                            contextAfter: contextAfter
                        )
                        matches.append(matchRecord)
                        emitted += 1

                        if format == .text {
                            if headers && !printedHeader {
                                print("--- PAGE \(pageNumber) ---")
                                printedHeader = true
                            }
                            if context > 0 {
                                contextBefore.forEach { print("C: \($0)") }
                            }
                            print("M: \(line)")
                            if context > 0 {
                                contextAfter.forEach { print("C: \($0)") }
                            }
                        }

                        if let maxMatches, emitted >= maxMatches {
                            output(matches: matches, format: format)
                            return
                        }
                    }
                }
            }

            output(matches: matches, format: format)
        }

        private func output(matches: [Match], format: OutputFormat) {
            guard format == .json else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            if let data = try? encoder.encode(matches) {
                print(String(decoding: data, as: UTF8.self))
            }
        }
    }

    struct Completions: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Generate shell completion script."
        )

        @Argument(
            help: "Shell to target (bash, zsh, fish). Defaults to current shell when detectable."
        )
        var shell: ShellArgument?

        func run() throws {
            // Prefer detected shell; otherwise require an explicit argument.
            let detected = CompletionShell.autodetected()
            let targetShell = shell?.asCompletionShell ?? detected
            guard let targetShell else {
                throw ValidationError("Unable to detect shell; please specify one (bash|zsh|fish).")
            }

            let script = PDF.completionScript(for: targetShell)
            print(script)
        }
    }
}

// MARK: - Helpers

enum CLIError: LocalizedError {
    case fileNotFound(String)
    case unreadablePDF(String)
    case invalidPageSpec(String, Int)
    case invalidTermsFile(String)
    case invalidContext(Int)
    case noKeywords

    var errorDescription: String? {
        switch self {
        case let .fileNotFound(path):
            return "No file exists at \(path)"
        case let .unreadablePDF(path):
            return "Unable to read PDF at \(path)"
        case let .invalidPageSpec(spec, max):
            return "Invalid page list \"\(spec)\". Pages must be between 1 and \(max)."
        case let .invalidTermsFile(path):
            return "Unable to read search terms from \(path)"
        case let .invalidContext(value):
            return "Context must be zero or positive. Received \(value)."
        case .noKeywords:
            return "No keywords provided. Supply --keyword or keep the default list."
        }
    }
}

enum PDFLoader {
    static func open(path: String) throws -> PDFDocument {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError.fileNotFound(path)
        }
        guard let document = PDFDocument(url: url) else {
            throw CLIError.unreadablePDF(path)
        }
        return document
    }
}

struct PageSelector {
    let pageNumbers: [Int]

    init(rawValue: String?, pageCount: Int) throws {
        guard let raw = rawValue, !raw.isEmpty else {
            pageNumbers = Array(1...pageCount)
            return
        }

        var pages = Set<Int>()
        let segments = raw.split(separator: ",")

        for segment in segments {
            let cleaned = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }

            if cleaned.contains("-") {
                let bounds = cleaned.split(separator: "-", maxSplits: 1).map { String($0) }
                guard bounds.count == 2, let start = Int(bounds[0]), let end = Int(bounds[1]), start > 0, end >= start else {
                    throw CLIError.invalidPageSpec(raw, pageCount)
                }
                for page in start...end { pages.insert(page) }
            } else {
                guard let page = Int(cleaned), page > 0 else {
                    throw CLIError.invalidPageSpec(raw, pageCount)
                }
                pages.insert(page)
            }
        }

        let validPages = pages.filter { $0 <= pageCount }
        guard !validPages.isEmpty else {
            throw CLIError.invalidPageSpec(raw, pageCount)
        }

        pageNumbers = validPages.sorted()
    }
}

struct Match: Codable {
    let page: Int
    let line: Int
    let text: String
    let contextBefore: [String]
    let contextAfter: [String]
}

enum OutputFormat: String, CaseIterable, ExpressibleByArgument {
    case text
    case json

    /// Per-case help surfaced in `--help` (ArgumentParser 1.6+).
    static func help(for value: OutputFormat) -> ArgumentHelp? {
        switch value {
        case .text:
            return "Human-readable matches with optional context."
        case .json:
            return "Machine-readable matches encoded as JSON."
        }
    }
}

enum MatchMode {
    case substring
    case regex
}

/// CLI-facing wrapper that bridges to `CompletionShell`.
struct ShellArgument: ExpressibleByArgument {
    let value: CompletionShell

    init?(argument: String) {
        guard let shell = CompletionShell(rawValue: argument) else { return nil }
        self.value = shell
    }

    var asCompletionShell: CompletionShell { value }
}

struct PatternMatcher {
    private let mode: MatchMode
    private let caseSensitive: Bool
    private let substrings: [String]
    private let regexes: [NSRegularExpression]

    init(keywords: [String], regex: Bool, caseSensitive: Bool) throws {
        self.mode = regex ? .regex : .substring
        self.caseSensitive = caseSensitive

        if regex {
            let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
            self.regexes = try keywords.map { try NSRegularExpression(pattern: $0, options: options) }
            self.substrings = []
        } else {
            self.substrings = caseSensitive ? keywords : keywords.map { $0.lowercased() }
            self.regexes = []
        }
    }

    func matches(line: String) -> Bool {
        switch mode {
        case .substring:
            let haystack = caseSensitive ? line : line.lowercased()
            return substrings.contains { haystack.contains($0) }
        case .regex:
            for regex in regexes {
                let range = NSRange(location: 0, length: line.utf16.count)
                if regex.firstMatch(in: line, options: [], range: range) != nil {
                    return true
                }
            }
            return false
        }
    }
}

enum SearchTermLoader {
    static func load(cliTerms: [String], termsFile: String?) throws -> [String] {
        var terms: [String] = []

        if let file = termsFile {
            guard FileManager.default.fileExists(atPath: file) else {
                throw CLIError.invalidTermsFile(file)
            }
            guard let contents = try? String(contentsOfFile: file, encoding: .utf8) else {
                throw CLIError.invalidTermsFile(file)
            }
            terms.append(contentsOf: splitTerms(contents))
        }

        terms.append(contentsOf: cliTerms.flatMap(splitTerms))
        return terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func splitTerms<S: StringProtocol>(_ input: S) -> [String] {
        // Accept comma separated or newline separated lists.
        return input
            .replacingOccurrences(of: "\n", with: ",")
            .split(separator: ",")
            .map(String.init)
    }
}

enum DefaultKeywords {
    static let values: [String] = [
        "delete",
        "deleted",
        "undelete",
        "snapshot",
        "snapshots",
        "history",
        "historical",
        "previous",
        "checkpoint",
        "checkpoints",
        "transaction",
        "transactions",
        "rollback",
        "extent",
        "extents",
        "block",
        "journal",
        "object map"
    ]
}
