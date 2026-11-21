import Foundation

public final class PptxPostProcessor {
    private static let imagePattern = #"!\[([^\]]*)\]\(([^)\s]+)(?:\s+"([^"]*)")?\)"#
    private static let srcPattern = #"\bsrc\s*=\s*(["'])(.*?)\1"#

    private let mediaDir: URL
    private let workdir: URL
    private let ocr: OCRService
    private let cache: OCRCache
    private let renderer: VectorRenderer
    private let useOCR: Bool
    private let onOCR: OCRHandler?
    private var preloadedText: [String: String] = [:]
    private let preloadedLock = NSLock()

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

    public func replaceImages(
        in markdown: String,
        imageCoords: [String: (x: Int, y: Int, width: Int, height: Int)],
        slideWidth: Int,
        slideHeight: Int
    ) -> String {
        guard let regex = RegexTools.compile(Self.imagePattern) else { return markdown }
        let current = markdown
        return RegexTools.replacingMatches(in: markdown, regex: regex) { match, ns in
            let alt = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let source = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            let title = match.range(at: 3).location == NSNotFound
                ? ""
                : ns.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces)
            let imagePath = resolve(source: source)
            let basename = URL(fileURLWithPath: source).lastPathComponent
            let label = !title.isEmpty ? title : (!alt.isEmpty ? alt : basename)
            let coordinates = imageCoords[title] ?? imageCoords[basename]
            let coordinateText = pptxCoords(coordinates, slideWidth: slideWidth, slideHeight: slideHeight)

            var text = ""
            var note = ""
            if !FileManager.default.fileExists(atPath: imagePath.path) {
                note = "<!-- image not extracted: \(label) -->"
            } else if !useOCR {
                note = "<!-- image omitted: \(label) (OCR disabled) -->"
            } else {
                text = ocrImageFile(imagePath)
                onOCR?()
                if !TextTools.usefulOCR(text) {
                    text = ""
                    return ""
                }
            }

            let context = RegexTools.lineContext(in: current as NSString, around: match.range)
            let inPipeTable = context.line.trimmingCharacters(in: .whitespaces).hasPrefix("|")

            let coordinateSuffix = coordinateText.isEmpty ? "" : "<br>**Position:** \(coordinateText)"
            if inPipeTable {
                var parts: [String] = []
                if !text.isEmpty {
                    let escaped = text
                        .replacingOccurrences(of: "|", with: "\\|")
                        .replacingOccurrences(of: "\n", with: "<br>")
                    parts.append("<br>**Image text (OCR) — \(label):** \(escaped)")
                }
                if !note.isEmpty { parts.append(note) }
                if !coordinateSuffix.isEmpty { parts.append(coordinateSuffix) }
                return parts.joined()
            }

            var pieces: [String] = []
            if !text.isEmpty { pieces.append(blockquote(text, label: label)) }
            if !note.isEmpty { pieces.append(note) }
            if !coordinateText.isEmpty { pieces.append("- **Position:** \(coordinateText)") }
            if pieces.isEmpty { return "<!-- image omitted: \(label) -->" }
            return "\n\n" + pieces.joined(separator: "\n\n") + "\n\n"
        }
    }

    public func appendSlideMeta(_ chunk: String, meta: PptxSlideMeta) -> String {
        var pieces = [chunk.trimmingCharacters(in: .whitespacesAndNewlines)]
        let notes = meta.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            pieces.append("")
            pieces.append("### Speaker notes")
            pieces.append("")
            pieces.append(contentsOf: notes.components(separatedBy: "\n").map {
                $0.trimmingCharacters(in: .whitespaces).isEmpty ? ">" : "> \($0)"
            })
        }
        if !meta.comments.isEmpty {
            pieces.append("")
            pieces.append("### Comments")
            pieces.append("")
            for (index, comment) in meta.comments.enumerated() {
                if index > 0 { pieces.append("") }
                pieces.append("> **\(comment.author) — \(comment.date)**")
                pieces.append(">")
                pieces.append(contentsOf: comment.text.components(separatedBy: "\n").map {
                    $0.trimmingCharacters(in: .whitespaces).isEmpty ? ">" : "> \($0)"
                })
            }
        }
        return pieces.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Collect the images referenced by the slide Markdown.
    public func collectImageURLs(in markdown: String) -> [URL] {
        guard let regex = RegexTools.compile(Self.imagePattern) else { return [] }
        var urls: [URL] = []
        var seen = Set<String>()
        let ns = markdown as NSString
        for match in regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
            let source = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            let path = resolve(source: source)
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            if seen.insert(path.standardizedFileURL.path).inserted {
                urls.append(path)
            }
        }
        return urls
    }

    /// Run the OCR for one slide image and put the result in the shared cache.
    public func preload(_ image: URL) {
        let key = image.standardizedFileURL.path
        let text = ocrImageFile(image)
        preloadedLock.lock()
        preloadedText[key] = text
        preloadedLock.unlock()
    }

    public func splitSlides(_ markdown: String) -> (preamble: String, chunks: [String]) {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = RegexTools.compile("(?m)^## ") else {
            return ("", trimmed.isEmpty ? [] : [trimmed])
        }
        let ns = markdown as NSString
        let matches = regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else {
            return ("", trimmed.isEmpty ? [] : [trimmed])
        }
        let preamble = matches[0].range.location == 0
            ? ""
            : ns.substring(to: matches[0].range.location).trimmingCharacters(in: .whitespacesAndNewlines)
        var chunks: [String] = []
        for (index, match) in matches.enumerated() {
            let start = match.range.location
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            chunks.append(
                ns.substring(with: NSRange(location: start, length: end - start))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return (preamble, chunks)
    }

    private func resolve(source: String) -> URL {
        let decoded = source.removingPercentEncoding ?? source
        let cleaned = TextTools.htmlUnescape(decoded).trimmingCharacters(in: .whitespaces)
        for base in [workdir, mediaDir] {
            let candidate = base.appendingPathComponent(cleaned).standardizedFileURL
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
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
        if DocxImageProcessor.vectorSuffixes.contains(suffix) {
            let png = workdir.appendingPathComponent("pptx_vector_\(UUID().uuidString).png")
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

    private func pptxCoords(
        _ coords: (x: Int, y: Int, width: Int, height: Int)?,
        slideWidth: Int,
        slideHeight: Int
    ) -> String {
        guard let coords, slideWidth > 0, slideHeight > 0 else { return "" }
        let top = pct(coords.y, slideHeight)
        let left = pct(coords.x, slideWidth)
        let width = pct(coords.width, slideWidth)
        let height = pct(coords.height, slideHeight)
        return "[top: \(top)%, left: \(left)%, width: \(width)%, height: \(height)%]"
    }

    private func pct(_ value: Int, _ total: Int) -> Int {
        guard total > 0 else { return 0 }
        let percent = Double(value) / Double(total) * 100.0
        return max(0, min(100, Int(percent / 10.0 + 0.5) * 10))
    }
}
