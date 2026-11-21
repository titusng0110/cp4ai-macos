import Foundation

public final class PDFPipeline {
    public static let ocrComment = "<!-- OCR text from image(s) on this page; the text existed only inside a picture and may contain recognition errors -->"

    private let helper: PDFHelperClient
    private let ocr: OCRService
    private let cache: OCRCache
    private let useOCR: Bool
    private let onPage: PageHandler?
    private let onOCR: OCRHandler?

    public init(
        helper: PDFHelperClient,
        ocr: OCRService,
        cache: OCRCache,
        useOCR: Bool,
        onPage: PageHandler?,
        onOCR: OCRHandler?
    ) {
        self.helper = helper
        self.ocr = ocr
        self.cache = cache
        self.useOCR = useOCR
        self.onPage = onPage
        self.onOCR = onOCR
    }

    public func convert(_ source: URL, to output: URL) throws -> String {
        let regions = try TemporaryDirectory(prefix: "cp4ai_pdf_")
        let document = try helper.extract(source, output: regions.url)
        return try convert(
            document: document,
            regionsDirectory: regions.url,
            source: source,
            to: output
        )
    }

    /// Assemble a PDF from an already-extracted helper document.
    public func convert(
        document: PDFDocument,
        regionsDirectory: URL,
        source: URL,
        to output: URL
    ) throws -> String {
        let total = document.pages.count
        var parts: [String] = []
        var ocrPages = 0

        for (index, page) in document.pages.enumerated() {
            let native = TextTools.clean(page.markdown)
            var blocks: [String] = []

            if useOCR {
                for image in page.images {
                    let file = regionsDirectory.appendingPathComponent(image.file)
                    let text: String
                    if let cached = cache.text(for: image.sha256) {
                        text = cached
                    } else {
                        text = (try? ocr.recognize(imageAt: file)) ?? ""
                        cache.store(text, for: image.sha256)
                    }
                    onOCR?()

                    guard TextTools.usefulOCR(text) else { continue }
                    guard !TextTools.isOrderedSubsequenceAfterStrippingWhitespace(text, of: native) else {
                        continue
                    }
                    blocks.append(
                        blockquote(
                            text: text,
                            label: image.kind == "page" ? "full page" : "image",
                            position: positionText(
                                bbox: image.bbox,
                                pageWidth: page.width,
                                pageHeight: page.height
                            )
                        )
                    )
                }
            }

            if !blocks.isEmpty { ocrPages += 1 }
            var body = native
            if !blocks.isEmpty {
                let ocr = Self.ocrComment + "\n\n" + blocks.joined(separator: "\n\n")
                body = body.isEmpty ? ocr : body + "\n\n" + ocr
            }
            parts.append(
                "<!-- page \(index + 1) of \(total) -->\n\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
            onPage?()
        }

        let header = TextTools.frontMatter(
            path: source,
            format: "pdf",
            extras: [
                ("pages", String(total)),
                ("text_extraction", "pymupdf \(document.pymupdf)"),
                (
                    "images_ocr",
                    useOCR
                        ? "\(ocr.label) (\(ocrPages) page(s) with OCR text)"
                        : "disabled"
                ),
            ]
        )
        let markdown = "\(header)\n\n# \(TextTools.title(of: source))\n\n" + parts.joined(separator: "\n\n")
        try TextTools.writeMarkdown(markdown, to: output)
        return "pdf, \(total) pages, OCR on \(ocrPages) page(s)"
    }

    private func blockquote(text: String, label: String, position: String) -> String {
        let heading = position.isEmpty
            ? "> **Image text (OCR) — \(label)**"
            : "> **Image text (OCR) — \(label) — \(position)**"
        var lines = [heading, ">"]
        lines.append(contentsOf: text.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .whitespaces).isEmpty ? ">" : "> \($0)"
        })
        return lines.joined(separator: "\n")
    }

    private func positionText(bbox: [Double], pageWidth: Double, pageHeight: Double) -> String {
        guard bbox.count == 4, pageWidth > 0, pageHeight > 0 else { return "" }
        let top = Int((bbox[1] / pageHeight * 100).rounded())
        let left = Int((bbox[0] / pageWidth * 100).rounded())
        let width = Int(((bbox[2] - bbox[0]) / pageWidth * 100).rounded())
        let height = Int(((bbox[3] - bbox[1]) / pageHeight * 100).rounded())
        return "[top: \(max(0, min(100, top)))%, left: \(max(0, min(100, left)))%, "
            + "width: \(max(0, min(100, width)))%, height: \(max(0, min(100, height)))%]"
    }
}
