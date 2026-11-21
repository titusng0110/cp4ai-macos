import Foundation

public struct ConversionOptions {
    public var useOCR: Bool
    public var jobs: Int
    public var ocrLanguages: [String]
    public var resources: CP4AIResources

    public init(
        useOCR: Bool = true,
        jobs: Int = max(1, ProcessInfo.processInfo.activeProcessorCount),
        ocrLanguages: [String] = ["en-US"],
        resources: CP4AIResources = .locate()
    ) {
        self.useOCR = useOCR
        self.jobs = max(1, jobs)
        self.ocrLanguages = ocrLanguages
        self.resources = resources
    }

    /// The Quick Action uses a lower cap so Vision does not exhaust memory.
    public static func quickAction(
        useOCR: Bool = true,
        resources: CP4AIResources = .locate()
    ) -> ConversionOptions {
        let cap = min(max(1, ProcessInfo.processInfo.activeProcessorCount), 6)
        return ConversionOptions(useOCR: useOCR, jobs: cap, resources: resources)
    }
}

public struct FileConversion {
    public let source: URL
    public let details: String
    public let markdown: String
}

public struct BatchResult {
    public let markdown: String
    public let characters: Int
    public let tokens: Int
    public let files: [URL]
}

public struct FileFailure {
    public let source: URL
    public let message: String

    public init(source: URL, message: String) {
        self.source = source
        self.message = message
    }
}

public struct BatchFailure: LocalizedError {
    public let errors: [FileFailure]

    public var errorDescription: String? {
        "\(errors.count) file(s) failed"
    }

    public init(errors: [FileFailure]) {
        self.errors = errors
    }
}

public struct WorkTotals {
    public var pages: Int
    public var ocr: Int

    public init(pages: Int = 0, ocr: Int = 0) {
        self.pages = pages
        self.ocr = ocr
    }
}

public struct WorkState {
    public var documentsTotal: Int
    public var documentsDone: Int
    public var imagesTotal: Int
    public var imagesDone: Int

    public init(
        documentsTotal: Int,
        imagesTotal: Int,
        documentsDone: Int = 0,
        imagesDone: Int = 0
    ) {
        self.documentsTotal = documentsTotal
        self.documentsDone = documentsDone
        self.imagesTotal = imagesTotal
        self.imagesDone = imagesDone
    }

    public var fraction: Double {
        let total = documentsTotal + imagesTotal
        guard total > 0 else { return 0 }
        return min(1.0, Double(documentsDone + imagesDone) / Double(total))
    }
}

public enum ProgressEvent {
    case work(WorkState)
    case fileStarted(index: Int, total: Int, source: URL)
    case fileFinished(index: Int, total: Int, source: URL, details: String?, error: String?)
}

public typealias ProgressHandler = (ProgressEvent) -> Void
public typealias PageHandler = () -> Void
public typealias OCRHandler = () -> Void

public enum ConversionError: LocalizedError {
    case unsupported(String)
    case missingTool(String)
    case processFailed(String)
    case invalidDocument(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let message): return message
        case .missingTool(let message): return message
        case .processFailed(let message): return message
        case .invalidDocument(let message): return message
        }
    }
}

public enum SourceFilter {
    public static let suffixes: Set<String> = [".docx", ".pdf", ".pptx"]

    public static func filter(_ paths: [URL]) -> (valid: [URL], rejected: [(URL, String)]) {
        var valid: [URL] = []
        var rejected: [(URL, String)] = []
        var seen = Set<String>()

        for raw in paths {
            let path = raw.standardizedFileURL
            let key = path.path
            if seen.contains(key) { continue }
            seen.insert(key)

            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                rejected.append((path, "directories are not supported"))
            } else if !exists {
                rejected.append((path, "not found"))
            } else if !FileManager.default.isReadableFile(atPath: path.path) {
                rejected.append((path, "not a regular file"))
            } else if !suffixes.contains("." + path.pathExtension.lowercased()) {
                rejected.append((path, "unsupported file type (expected .docx, .pdf or .pptx)"))
            } else {
                valid.append(path)
            }
        }
        return (valid, rejected)
    }

    public static func sortedByName(_ paths: [URL]) -> [URL] {
        paths.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }
}
