import Foundation

public final class DocxImageProcessor {
    public static let imageSuffixes: Set<String> = [
        ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tif", ".tiff", ".webp",
        ".emf", ".wmf", ".svg",
    ]
    public static let vectorSuffixes: Set<String> = [".emf", ".wmf", ".svg"]

    private static let imagePattern = #"!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#
    private static let htmlImagePattern = #"<img\b[^>]*>"#
    private static let srcPattern = #"\bsrc\s*=\s*(["'])(.*?)\1"#
    private static let altPattern = #"\balt\s*=\s*(["'])(.*?)\1"#

    private let mediaDir: URL
    private let workdir: URL
    private let ocr: OCRService
    private let cache: OCRCache
    private let renderer: VectorRenderer
    private let useOCR: Bool
    private let onOCR: OCRHandler?

    private var counter = 0
    private var preloadedText: [String: String] = [:]
    private let preloadedLock = NSLock()
    private var referenced = Set<String>()
    private var failedVectors: [URL] = []

    public init(
        mediaDir: URL,
        workdir: URL,
        ocr: OCRService,
        cache: OCRCache,
        renderer: VectorRenderer,
        useOCR: Bool,
        onOCR: OCRHandler?
    ) {
        self.mediaDir = mediaDir
        self.workdir = workdir
        self.ocr = ocr
        self.cache = cache
        self.renderer = renderer
        self.useOCR = useOCR
        self.onOCR = onOCR
    }

    public func replaceImages(in markdown: String) -> String {
        var value = markdown
        if let regex = RegexTools.compile(Self.imagePattern) {
            value = RegexTools.replacingMatches(in: value, regex: regex) { match, ns in
                let alt = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let source = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                let (text, label, note) = imageText(source: source, alt: alt)
                if let note { return note }

                let context = RegexTools.lineContext(in: markdown as NSString, around: match.range)
                if context.line.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    let escaped = text.replacingOccurrences(of: "|", with: "\\|")
                        .replacingOccurrences(of: "\n", with: "<br>")
                    return "<br>**Image text (OCR) — \(label):** \(escaped)"
                }
                return "\n\n" + blockquote(text, label: label) + "\n\n"
            }
        }

        if let regex = RegexTools.compile(Self.htmlImagePattern, options: [.caseInsensitive]) {
            value = RegexTools.replacingMatches(in: value, regex: regex) { match, ns in
                let tag = ns.substring(with: match.range)
                guard let source = firstGroup(Self.srcPattern, in: tag, group: 2) else {
                    return "<!-- image not extracted: missing src -->"
                }
                let alt = firstGroup(Self.altPattern, in: tag, group: 2).map(TextTools.htmlUnescape) ?? ""
                let (text, label, note) = imageText(source: source, alt: alt)
                if let note { return note }

                let context = RegexTools.lineContext(in: markdown as NSString, around: match.range)
                let prefix = (markdown as NSString).substring(to: match.range.location).lowercased()
                let inTable = prefix.components(separatedBy: "<table").count
                    > prefix.components(separatedBy: "</table>").count
                    || context.line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
                    || context.line.contains("<td")
                    || context.line.contains("<th")
                let standalone = context.line.trimmingCharacters(in: .whitespaces)
                    == tag.trimmingCharacters(in: .whitespaces)

                if standalone && !inTable {
                    return "\n\n" + blockquote(text, label: label) + "\n\n"
                }
                var escaped = TextTools.htmlEscape(text).replacingOccurrences(of: "\n", with: "<br>")
                if inTable {
                    escaped = escaped.replacingOccurrences(of: "|", with: "\\|")
                }
                return "<br>**Image text (OCR) — \(TextTools.htmlEscape(label)):** \(escaped)"
            }
        }
        return value
    }

    public func figuresSection() -> (section: String, count: Int, failed: [URL]) {
        guard useOCR else { return ("", 0, []) }
        guard let enumerator = FileManager.default.enumerator(
            at: mediaDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ("", 0, [])
        }

        var files: [URL] = []
        for case let file as URL in enumerator {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            guard Self.imageSuffixes.contains("." + file.pathExtension.lowercased()) else { continue }
            files.append(file)
        }
        files.sort { TextTools.naturalCompare($0.lastPathComponent, $1.lastPathComponent) }

        var figures: [(String, String)] = []
        var failed: [URL] = []
        for file in files {
            if referenced.contains(file.standardizedFileURL.path) { continue }
            let text = ocrImageFile(file)
            onOCR?()
            if TextTools.usefulOCR(text) {
                figures.append((file.lastPathComponent, text))
            } else if Self.vectorSuffixes.contains("." + file.pathExtension.lowercased()) {
                failed.append(file)
            }
        }

        guard !figures.isEmpty else { return ("", 0, failed) }
        var output = [
            "## Figures from the original document (OCR text)",
            "",
            "> Pandoc could not position these floating/anchored drawings in the body, but the images were still present in the DOCX. Their text is reproduced below in image order and may contain recognition errors.",
        ]
        for (number, figure) in figures.enumerated() {
            output.append("")
            output.append("### Figure \(number + 1) — \(figure.0)")
            output.append("")
            output.append(contentsOf: figure.1.components(separatedBy: "\n").map {
                $0.trimmingCharacters(in: .whitespaces).isEmpty ? ">" : "> \($0)"
            })
        }
        return (output.joined(separator: "\n"), figures.count, failed)
    }

    public func vectorNote() -> String {
        guard !failedVectors.isEmpty else { return "" }
        var lines = [
            "## Vector images (not OCR'd)",
            "",
            "> The original DOCX contains EMF/WMF/SVG vector drawings that could not be rendered to a raster image for OCR. They are listed below; consult the original DOCX if their visual detail is needed.",
            "",
        ]
        lines.append(contentsOf: failedVectors.map { "- `\($0.lastPathComponent)`" })
        return lines.joined(separator: "\n")
    }

    public func failedVectorFiles() -> [URL] {
        failedVectors
    }

    /// Collect every image that the final replacement pass may OCR, without
    /// mutating the processor's replacement counters.
    public func collectImageURLs(in markdown: String) -> [URL] {
        var urls: [URL] = []
        var seen = Set<String>()

        func add(_ source: String) {
            let path = resolve(source: source)
            guard FileManager.default.fileExists(atPath: path.path) else { return }
            if seen.insert(path.standardizedFileURL.path).inserted {
                urls.append(path)
            }
        }

        if let regex = RegexTools.compile(Self.imagePattern) {
            let ns = markdown as NSString
            for match in regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
                add(ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces))
            }
        }
        if let regex = RegexTools.compile(Self.htmlImagePattern, options: [.caseInsensitive]) {
            let ns = markdown as NSString
            for match in regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
                let tag = ns.substring(with: match.range)
                if let source = firstGroup(Self.srcPattern, in: tag, group: 2) {
                    add(source)
                }
            }
        }
        return urls
    }

    /// All image files extracted by Pandoc, including floating figures.
    public func mediaImageURLs() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: mediaDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var urls: [URL] = []
        for case let file as URL in enumerator {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            if Self.imageSuffixes.contains("." + file.pathExtension.lowercased()) {
                urls.append(file)
            }
        }
        return urls
    }

    /// Run the OCR for one image and put the result in the shared cache.
    public func preload(_ image: URL) {
        let key = image.standardizedFileURL.path
        let text = ocrImageFile(image)
        preloadedLock.lock()
        preloadedText[key] = text
        preloadedLock.unlock()
    }

    public func addFailedVectors(_ urls: [URL]) {
        failedVectors.append(contentsOf: urls)
        let unique = Dictionary(grouping: failedVectors, by: { $0.standardizedFileURL.path })
            .compactMap { $0.value.first }
        failedVectors = unique.sorted { TextTools.naturalCompare($0.lastPathComponent, $1.lastPathComponent) }
    }

    private func imageText(source: String, alt: String) -> (String, String, String?) {
        let imagePath = resolve(source: source)
        let label = alt.trimmingCharacters(in: .whitespaces).isEmpty
            ? URL(fileURLWithPath: source).lastPathComponent
            : alt.trimmingCharacters(in: .whitespaces)
        guard FileManager.default.fileExists(atPath: imagePath.path) else {
            return ("", label, "<!-- image not extracted: \(label) -->")
        }
        counter += 1
        referenced.insert(imagePath.standardizedFileURL.path)
        guard useOCR else {
            return ("", label, "<!-- image omitted: \(label) (OCR disabled) -->")
        }
        let text = ocrImageFile(imagePath)
        onOCR?()
        if TextTools.usefulOCR(text) {
            return (text, label, nil)
        }
        if Self.vectorSuffixes.contains("." + imagePath.pathExtension.lowercased()) {
            failedVectors.append(imagePath)
            return ("", label, "<!-- vector image not OCR'd: \(label) -->")
        }
        // Fewer than 10 non-whitespace characters: drop the image entirely.
        return ("", label, "")
    }

    private func resolve(source: String) -> URL {
        let decoded = source.removingPercentEncoding ?? source
        let cleaned = TextTools.htmlUnescape(decoded).trimmingCharacters(in: .whitespaces)
        for base in [workdir, mediaDir] {
            let candidate = base.appendingPathComponent(cleaned).standardizedFileURL
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return workdir.appendingPathComponent(cleaned).standardizedFileURL
    }

    private func ocrImageFile(_ image: URL) -> String {
        let key = image.standardizedFileURL.path
        preloadedLock.lock()
        if let cached = preloadedText[key] {
            preloadedLock.unlock()
            return cached
        }
        preloadedLock.unlock()

        let suffix = "." + image.pathExtension.lowercased()
        if Self.vectorSuffixes.contains(suffix) {
            let png = workdir.appendingPathComponent("vector_\(UUID().uuidString).png")
            guard renderer.vectorToPNG(image, outPNG: png, workdir: workdir) else { return "" }
            return ocrImageCached(png)
        }
        return ocrImageCached(image)
    }

    private func ocrImageCached(_ image: URL) -> String {
        let key = "." + image.pathExtension.lowercased() + ":" + OCRCache.digest(of: image)
        if let cached = cache.text(for: key) { return cached }
        let text = (try? ocr.recognize(imageAt: image)) ?? ""
        cache.store(text, for: key)
        return text
    }

    private func blockquote(_ text: String, label: String) -> String {
        var lines = ["> **Image text (OCR) — \(label)**", ">"]
        lines.append(contentsOf: text.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .whitespaces).isEmpty ? ">" : "> \($0)"
        })
        return lines.joined(separator: "\n")
    }

    private func firstGroup(_ pattern: String, in text: String, group: Int) -> String? {
        guard let regex = RegexTools.compile(pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              group < match.numberOfRanges,
              match.range(at: group).location != NSNotFound else {
            return nil
        }
        return ns.substring(with: match.range(at: group))
    }
}
