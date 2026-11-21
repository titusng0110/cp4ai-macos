import AppKit
import CP4AICore
import Darwin
import Foundation

public enum CP4AICLI {
    public static func run() -> Int32 {
        let name = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
        let mode: Mode = name == "md4ai" ? .md4ai : .cp4ai
        let arguments = Array(CommandLine.arguments.dropFirst())

        if arguments.contains("--version") {
            print("\(mode.commandName) \(CP4AIVersion.current)")
            return 0
        }
        if arguments.contains("-h") || arguments.contains("--help") {
            print(help(mode))
            return 0
        }
        if arguments.isEmpty {
            print(help(mode))
            return 0
        }

        do {
            let options = try parse(arguments, mode: mode)
            switch mode {
            case .cp4ai:
                return try runCopy(options)
            case .md4ai:
                return try runMarkdown(options)
            }
        } catch let error as CLIError {
            fputs("ERROR: \(error.message)\n", stderr)
            return 1
        } catch {
            fputs("ERROR: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func runCopy(_ arguments: Arguments) throws -> Int32 {
        let (sources, rejected) = SourceFilter.filter(arguments.files.map { URL(fileURLWithPath: $0).standardizedFileURL })
        for (url, reason) in rejected {
            fputs("ERROR: \(url.path): \(reason)\n", stderr)
        }
        if !rejected.isEmpty { return 1 }
        guard !sources.isEmpty else {
            fputs("ERROR: no files to convert\n", stderr)
            return 1
        }

        let options = ConversionOptions(
            useOCR: !arguments.noOCR,
            jobs: arguments.jobs,
            ocrLanguages: arguments.languages
        )
        let engine = ConversionEngine(options: options)
        let reporter = CLIProgressReporter()
        defer { reporter.finish() }
        let printer = OrderedFileProgress { _, _, source, details, error in
            if let error {
                fputs("[\(source.lastPathComponent)] FAILED: \(error)\n", stderr)
            } else if let details {
                print("[done] \(source.lastPathComponent) (\(details))")
            }
        }
        let progress: ProgressHandler = { event in
            switch event {
            case .work(let state):
                reporter.work(state)
            case .fileStarted(let index, let total, let source):
                reporter.started(index: index, total: total, source: source)
            case .fileFinished(let index, let total, let source, let details, let error):
                reporter.clearLine()
                printer.add(index: index, total: total, source: source, details: details, error: error)
            }
        }

        let result: BatchResult
        do {
            result = try engine.convertBatch(sources: sources, progress: progress)
        } catch let failure as BatchFailure {
            fputs("\(failure.errors.count) file(s) failed; clipboard not changed\n", stderr)
            return 1
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(result.markdown, forType: .string) else {
            fputs("ERROR: could not write to the clipboard\n", stderr)
            return 1
        }
        print(String(repeating: "=", count: 25))
        print("Copied to clipboard! (\(result.characters) characters / \(result.tokens) tokens)")
        return 0
    }

    private static func runMarkdown(_ arguments: Arguments) throws -> Int32 {
        guard let rawTarget = arguments.files.first else {
            print(help(.md4ai))
            return 0
        }
        let target = URL(fileURLWithPath: rawTarget).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
            throw CLIError("not found: \(target.path)")
        }

        let sources: [URL]
        if isDirectory.boolValue {
            guard arguments.recursive else {
                throw CLIError("\(target.path) is a directory; pass -r/--recursive")
            }
            sources = collectSources(under: target)
        } else {
            guard SourceFilter.suffixes.contains("." + target.pathExtension.lowercased()) else {
                throw CLIError("unsupported file type: \(target.path) (expected .docx, .pdf or .pptx)")
            }
            sources = [target]
        }
        guard !sources.isEmpty else {
            throw CLIError("no .docx/.pdf/.pptx files found under \(target.path)")
        }

        let planned = try planOutputs(sources: sources, target: target, out: arguments.out)
        try checkOutputs(planned, force: arguments.force)

        let options = ConversionOptions(
            useOCR: !arguments.noOCR,
            jobs: arguments.jobs,
            ocrLanguages: arguments.languages
        )
        let engine = ConversionEngine(options: options)
        let reporter = CLIProgressReporter()
        defer { reporter.finish() }
        let printer = OrderedFileProgress { index, total, source, details, error in
            if let error {
                fputs("[\(index)/\(total)] FAILED \(source.path): \(error)\n", stderr)
            } else if let details, index - 1 < planned.count {
                print("[\(index)/\(total)] \(source.path) -> \(planned[index - 1].output.path) (\(details))")
            }
        }
        let progress: ProgressHandler = { event in
            switch event {
            case .work(let state):
                reporter.work(state)
            case .fileStarted(let index, let total, let source):
                reporter.started(index: index, total: total, source: source)
            case .fileFinished(let index, let total, let source, let details, let error):
                reporter.clearLine()
                printer.add(index: index, total: total, source: source, details: details, error: error)
            }
        }

        do {
            _ = try engine.convertBatch(
                sources: planned.map(\.source),
                outputURLs: planned.map(\.output),
                progress: progress
            )
        } catch let failure as BatchFailure {
            fputs("\(failure.errors.count) file(s) failed\n", stderr)
            return 1
        }
        return 0
    }

    private static func collectSources(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var sources: [URL] = []
        for case let file as URL in enumerator {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            guard SourceFilter.suffixes.contains("." + file.pathExtension.lowercased()) else { continue }
            guard !file.lastPathComponent.hasPrefix("~$") else { continue }
            sources.append(file)
        }
        return sources.sorted { $0.path.lowercased() < $1.path.lowercased() }
    }

    private static func planOutputs(
        sources: [URL],
        target: URL,
        out: String?
    ) throws -> [(source: URL, output: URL)] {
        guard let out else {
            return sources.map { ($0, $0.appendingPathExtension("md")) }
        }

        let outURL = URL(fileURLWithPath: (out as NSString).expandingTildeInPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: outURL.path, isDirectory: &isDirectory)
        let looksLikeDirectory = (exists && isDirectory.boolValue) || out.hasSuffix("/") || outURL.pathExtension.lowercased() != "md"

        var targetIsDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: target.path, isDirectory: &targetIsDirectory)
        if targetIsDirectory.boolValue {
            guard looksLikeDirectory else {
                throw CLIError("--out must be a directory when converting a directory")
            }
            return sources.map { source in
                let relative = source.path.removingPrefix(target.path + "/") ?? source.lastPathComponent
                let directory = (relative as NSString).deletingLastPathComponent
                let output = outURL.appendingPathComponent(directory)
                    .appendingPathComponent(source.lastPathComponent + ".md")
                return (source, output)
            }
        }

        guard let source = sources.first else { return [] }
        if looksLikeDirectory {
            return [(source, outURL.appendingPathComponent(source.lastPathComponent + ".md"))]
        }
        return [(source, outURL)]
    }

    private static func checkOutputs(_ planned: [(source: URL, output: URL)], force: Bool) throws {
        let outputs = planned.map(\.output.standardizedFileURL.path)
        if Set(outputs).count != outputs.count {
            throw CLIError("multiple inputs map to the same output path")
        }
        for output in planned.map(\.output) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: output.path, isDirectory: &isDirectory), isDirectory.boolValue {
                throw CLIError("output path is a directory: \(output.path)")
            }
        }
        if !force {
            let existing = planned.map(\.output).filter { FileManager.default.fileExists(atPath: $0.path) }
            if !existing.isEmpty {
                let listing = existing.map { "  \($0.path)" }.joined(separator: "\n")
                throw CLIError("refusing to overwrite existing output (use -f/--force):\n\(listing)")
            }
        }
    }

    private static func parse(_ args: [String], mode: Mode) throws -> Arguments {
        var result = Arguments()
        result.files = []
        var index = 0
        var literal = false

        while index < args.count {
            let argument = args[index]
            if literal {
                result.files.append(argument)
                index += 1
                continue
            }
            if argument == "--" {
                literal = true
                index += 1
                continue
            }
            if argument == "--no-ocr" {
                result.noOCR = true
                index += 1
                continue
            }
            if argument == "-r" || argument == "--recursive" {
                guard mode == .md4ai else {
                    throw CLIError("unknown option: \(argument)")
                }
                result.recursive = true
                index += 1
                continue
            }
            if argument == "-f" || argument == "--force" {
                guard mode == .md4ai else {
                    throw CLIError("unknown option: \(argument)")
                }
                result.force = true
                index += 1
                continue
            }
            if mode == .md4ai, argument.hasPrefix("-"), !argument.hasPrefix("--"), argument.count > 2 {
                let flags = argument.dropFirst()
                if flags.allSatisfy({ $0 == "r" || $0 == "f" }) {
                    if flags.contains("r") { result.recursive = true }
                    if flags.contains("f") { result.force = true }
                    index += 1
                    continue
                }
            }
            if argument == "-o" || argument == "--out" {
                guard mode == .md4ai, index + 1 < args.count else {
                    throw CLIError("\(argument) needs a value")
                }
                result.out = args[index + 1]
                index += 2
                continue
            }
            if argument.hasPrefix("--out=") {
                guard mode == .md4ai else { throw CLIError("unknown option: \(argument)") }
                result.out = String(argument.dropFirst("--out=".count))
                index += 1
                continue
            }
            if argument == "--jobs" {
                guard index + 1 < args.count, let value = Int(args[index + 1]), value > 0 else {
                    throw CLIError("--jobs needs a positive integer")
                }
                result.jobs = value
                index += 2
                continue
            }
            if argument.hasPrefix("--jobs=") {
                guard let value = Int(argument.dropFirst("--jobs=".count)), value > 0 else {
                    throw CLIError("--jobs needs a positive integer")
                }
                result.jobs = value
                index += 1
                continue
            }
            if argument == "--languages" {
                guard index + 1 < args.count else { throw CLIError("--languages needs a value") }
                result.languages = parseLanguages(args[index + 1])
                index += 2
                continue
            }
            if argument.hasPrefix("--languages=") {
                result.languages = parseLanguages(String(argument.dropFirst("--languages=".count)))
                index += 1
                continue
            }
            if argument.hasPrefix("-") {
                throw CLIError("unknown option: \(argument)")
            }
            result.files.append(argument)
            index += 1
        }

        if result.jobs < 1 {
            result.jobs = max(1, ProcessInfo.processInfo.activeProcessorCount)
        }
        return result
    }

    private static func parseLanguages(_ raw: String) -> [String] {
        let languages = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return languages.isEmpty ? ["en-US"] : languages
    }

    private static func help(_ mode: Mode) -> String {
        switch mode {
        case .cp4ai:
            return """
            usage: cp4ai [options] files...

            Convert DOCX, PDF and PPTX files to recall-first Markdown and copy
            the concatenated result to the clipboard.

            options:
              --no-ocr              do not OCR images
              --jobs N              parallel workers (default: CPU cores)
              --languages LIST      OCR languages, comma separated (default: en-US)
              -h, --help            show this help
              --version             show the version
            """
        case .md4ai:
            return """
            usage: md4ai [options] target

            Convert DOCX, PDF and PPTX files to recall-first Markdown.  By
            default a.pdf becomes a.pdf.md next to it.

            positional arguments:
              target                .docx/.pdf/.pptx file, or a directory with -r

            options:
              -r, --recursive       convert every .docx/.pdf/.pptx under a directory
              -f, --force           overwrite existing Markdown output
              -o, --out PATH        write to this .md file, or to this directory
                                    preserving structure
              --no-ocr              do not OCR images
              --jobs N              parallel workers (default: CPU cores)
              --languages LIST      OCR languages, comma separated (default: en-US)
              -h, --help            show this help
              --version             show the version
            """
        }
    }
}

private enum Mode {
    case cp4ai
    case md4ai

    var commandName: String {
        switch self {
        case .cp4ai: return "cp4ai"
        case .md4ai: return "md4ai"
        }
    }
}

private struct Arguments {
    var files: [String] = []
    var jobs: Int = 0
    var noOCR = false
    var languages: [String] = ["en-US"]
    var recursive = false
    var force = false
    var out: String?
}

private struct CLIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Buffers per-file results and prints them in input order even when files
/// finish out of order with `--jobs > 1`.
private final class OrderedFileProgress {
    private let lock = NSLock()
    private var next = 1
    private var pending: [Int: (source: URL, details: String?, error: String?)] = [:]
    private let emit: (Int, Int, URL, String?, String?) -> Void

    init(_ emit: @escaping (Int, Int, URL, String?, String?) -> Void) {
        self.emit = emit
    }

    func add(index: Int, total: Int, source: URL, details: String?, error: String?) {
        lock.lock()
        defer { lock.unlock() }
        pending[index] = (source, details, error)
        while let entry = pending[next] {
            pending.removeValue(forKey: next)
            emit(next, total, entry.source, entry.details, entry.error)
            next += 1
        }
    }
}

/// Live terminal feedback while extraction/OCR jobs are running.
private final class CLIProgressReporter {
    private let lock = NSLock()
    private let tty = isatty(STDERR_FILENO) != 0
    private var lastUpdate = Date.distantPast
    private var lastDocumentsDone = -1
    private var lineActive = false

    func started(index: Int, total: Int, source: URL) {
        lock.lock()
        defer { lock.unlock() }
        clearLineLocked()
        write("[working] \(source.lastPathComponent)\n")
    }

    func work(_ state: WorkState) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let documentsChanged = state.documentsDone != lastDocumentsDone
        guard tty || documentsChanged || now.timeIntervalSince(lastUpdate) >= 1.0 else { return }
        lastUpdate = now
        lastDocumentsDone = state.documentsDone
        var line = "Progress: \(state.documentsDone)/\(state.documentsTotal) documents"
        if state.imagesTotal > 0 || state.imagesDone > 0 {
            line += " + \(state.imagesDone)/\(state.imagesTotal) images"
        }
        if tty {
            write("\r\u{001B}[2K" + line)
            lineActive = true
        } else {
            write(line + "\n")
        }
    }

    func clearLine() {
        lock.lock()
        defer { lock.unlock() }
        clearLineLocked()
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        if lineActive {
            clearLineLocked()
            write("\n")
        }
    }

    private func clearLineLocked() {
        if lineActive {
            write("\r\u{001B}[2K")
            lineActive = false
        }
    }

    private func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}
