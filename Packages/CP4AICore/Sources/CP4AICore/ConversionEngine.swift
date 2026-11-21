import Foundation

public final class ConversionEngine {
    public let options: ConversionOptions
    private let pandoc: PandocRunner
    private let ocr: OCRService
    private let renderer: VectorRenderer
    private let pdfHelper: PDFHelperClient
    private let tokenizer: TokenCounter?

    public init(options: ConversionOptions) {
        self.options = options
        pandoc = PandocRunner(resources: options.resources)
        ocr = OCRService(languages: options.ocrLanguages)
        renderer = VectorRenderer(resources: options.resources)
        pdfHelper = PDFHelperClient(resources: options.resources)
        if let url = options.resources.tokenizer, let counter = try? TokenCounter(vocabURL: url) {
            tokenizer = counter
        } else {
            tokenizer = nil
        }
    }

    public func convertOne(
        _ source: URL,
        to output: URL,
        onPage: PageHandler? = nil,
        onOCR: OCRHandler? = nil
    ) throws -> String {
        switch source.pathExtension.lowercased() {
        case "docx":
            return try convertDOCX(source, output: output, onOCR: onOCR)
        case "pptx":
            return try convertPPTX(source, output: output, onPage: onPage, onOCR: onOCR)
        case "pdf":
            return try convertPDF(source, output: output, onPage: onPage, onOCR: onOCR)
        default:
            throw ConversionError.unsupported("unsupported file type: \(source.path)")
        }
    }

    public func convertBatch(
        sources: [URL],
        outputURLs: [URL]? = nil,
        progress: ProgressHandler? = nil
    ) throws -> BatchResult {
        precondition(!sources.isEmpty, "convertBatch needs at least one source")
        if let outputURLs {
            precondition(outputURLs.count == sources.count, "output count must match sources")
        }

        let temporary: TemporaryDirectory?
        let outputs: [URL]
        if let outputURLs {
            outputs = outputURLs
            temporary = nil
        } else {
            let directory = try TemporaryDirectory(prefix: "cp4ai_clipboard_")
            temporary = directory
            outputs = sources.indices.map { directory.url.appendingPathComponent(String(format: "%04d.md", $0)) }
        }
        _ = temporary

        let estimate = countWork(sources)
        let tracker = BatchProgressTracker(
            documentsTotal: sources.count,
            imagesTotal: estimate.ocr,
            progress: progress
        )
        tracker.start()

        let queue = JobQueue(maxConcurrent: max(1, options.jobs))
        var works: [DocumentWork] = []

        for (index, source) in sources.enumerated() {
            let work = DocumentWork(
                index: index,
                source: source,
                output: outputs[index],
                progress: tracker
            )
            works.append(work)

            queue.add { [weak self] in
                guard let self else { return }
                progress?(.fileStarted(index: index + 1, total: sources.count, source: source))
                do {
                    switch source.pathExtension.lowercased() {
                    case "docx":
                        work.context = .docx(try self.prepareDOCX(source, work: work, queue: queue))
                    case "pptx":
                        work.context = .pptx(try self.preparePPTX(source, work: work, queue: queue))
                    case "pdf":
                        work.context = .pdf(try self.preparePDF(source, work: work, queue: queue))
                    default:
                        throw ConversionError.unsupported("unsupported file type: \(source.path)")
                    }
                    work.extractionFinished()
                } catch {
                    work.fail(error.localizedDescription)
                }
            }
        }

        queue.drain()
        tracker.reconcile()

        var errors: [FileFailure] = []
        var rendered: [Int: String] = [:]

        // Insertion and document ordering happen only after every extraction
        // and OCR job has completed.
        for work in works {
            if let message = work.failure() {
                errors.append(FileFailure(source: work.source, message: message))
                progress?(.fileFinished(
                    index: work.index + 1,
                    total: sources.count,
                    source: work.source,
                    details: nil,
                    error: message
                ))
                continue
            }
            guard let context = work.context else {
                let message = "conversion did not produce a document context"
                errors.append(FileFailure(source: work.source, message: message))
                progress?(.fileFinished(
                    index: work.index + 1,
                    total: sources.count,
                    source: work.source,
                    details: nil,
                    error: message
                ))
                continue
            }
            do {
                let details: String
                switch context {
                case .docx(let value):
                    details = try assembleDOCX(value, source: work.source, output: work.output)
                case .pptx(let value):
                    details = try assemblePPTX(value, source: work.source, output: work.output)
                case .pdf(let value):
                    details = try assemblePDF(value, source: work.source, output: work.output)
                }
                let body = (try? String(contentsOf: work.output, encoding: .utf8)) ?? ""
                rendered[work.index] = body
                progress?(.fileFinished(
                    index: work.index + 1,
                    total: sources.count,
                    source: work.source,
                    details: details,
                    error: nil
                ))
            } catch {
                let message = error.localizedDescription
                errors.append(FileFailure(source: work.source, message: message))
                progress?(.fileFinished(
                    index: work.index + 1,
                    total: sources.count,
                    source: work.source,
                    details: nil,
                    error: message
                ))
            }
        }

        if !errors.isEmpty {
            throw BatchFailure(errors: errors)
        }

        var sections: [String] = []
        for (index, source) in sources.enumerated() {
            let body = (rendered[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            sections.append("[\(source.lastPathComponent) BEGIN]\n\(body)\n[\(source.lastPathComponent) END]")
        }
        let markdown = sections.joined(separator: "\n\n") + "\n"
        let tokens = tokenizer?.count(markdown) ?? 0
        return BatchResult(
            markdown: markdown,
            characters: markdown.unicodeScalars.count,
            tokens: tokens,
            files: sources
        )
    }

    public func countWork(_ sources: [URL]) -> WorkTotals {
        var totals = WorkTotals()
        for source in sources {
            switch source.pathExtension.lowercased() {
            case "pdf":
                if let probe = try? pdfHelper.probe(source) {
                    totals.pages += probe.pageCount
                    totals.ocr += probe.ocrJobs
                }
            case "docx":
                totals.pages += 1
                if let archive = try? OfficeArchive(url: source) {
                    totals.ocr += archive.files(in: "word/media").filter {
                        DocxImageProcessor.imageSuffixes.contains("." + ($0 as NSString).pathExtension.lowercased())
                    }.count
                }
            case "pptx":
                let slides = PptxMetadata.slides(at: source)
                totals.pages += slides.count
                totals.ocr += slides.reduce(0) { $0 + $1.images.count }
            default:
                break
            }
        }
        return totals
    }

    // MARK: - DOCX

    private func convertDOCX(_ source: URL, output: URL, onOCR: OCRHandler?) throws -> String {
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporary = try TemporaryDirectory(prefix: "cp4ai_docx_")
        let pandocBody = try pandoc.convertDOCX(source, workdir: temporary.url)
        let mediaDir = temporary.url.appendingPathComponent("media")
        let cache = OCRCache()
        let processor = DocxImageProcessor(
            mediaDir: mediaDir,
            workdir: temporary.url,
            ocr: ocr,
            cache: cache,
            renderer: renderer,
            useOCR: options.useOCR,
            onOCR: onOCR
        )

        var body = processor.replaceImages(in: pandocBody)
        let figures = processor.figuresSection()
        processor.addFailedVectors(figures.failed)
        let comments = DocxMetadata.comments(at: source)
        let inserted = CommentPlacement.insert(markdown: body, comments: comments)
        body = inserted.markdown
        let header = DocxMetadata.header(at: source)

        let front = TextTools.frontMatter(
            path: source,
            format: "docx",
            extras: [
                ("converter", "pandoc \(pandoc.version)"),
                ("header", header.isEmpty ? nil : header),
                ("comments", comments.isEmpty ? nil : String(comments.count)),
                ("images_ocr", options.useOCR ? ocr.label : "disabled"),
            ]
        )

        var pieces = [front, "", "# \(TextTools.title(of: source))", ""]
        if !header.isEmpty {
            pieces.append("> **Original document header:** \(header)")
            pieces.append("")
        }
        pieces.append(body)
        pieces.append("")
        pieces.append(figures.section)
        pieces.append(CommentPlacement.appendix(inserted.unplaced))
        pieces.append(processor.vectorNote())

        try TextTools.writeMarkdown(pieces.joined(separator: "\n"), to: output)
        return "docx, \(comments.count) comment(s), \(figures.count) floating figure(s), \(processor.failedVectorFiles().count) vector image(s) not OCR'd"
    }

    // MARK: - PPTX

    private func convertPPTX(_ source: URL, output: URL, onPage: PageHandler?, onOCR: OCRHandler?) throws -> String {
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let metadata = PptxMetadata.slides(at: source)
        let temporary = try TemporaryDirectory(prefix: "cp4ai_pptx_")
        let pandocBody = try pandoc.convertPPTX(source, workdir: temporary.url)
        let mediaDir = temporary.url.appendingPathComponent("media")
        let cache = OCRCache()
        let processor = PptxPostProcessor(
            mediaDir: mediaDir,
            workdir: temporary.url,
            ocr: ocr,
            cache: cache,
            renderer: renderer,
            useOCR: options.useOCR,
            onOCR: onOCR
        )

        var split = processor.splitSlides(pandocBody)
        if !split.preamble.isEmpty, !split.chunks.isEmpty {
            split.chunks[0] = split.preamble + "\n\n" + split.chunks[0]
        } else if !split.preamble.isEmpty {
            split.chunks = [split.preamble]
        }

        let total = max(split.chunks.count, metadata.count)
        var rendered: [String] = []
        for index in 0..<total {
            let chunk = index < split.chunks.count ? split.chunks[index] : ""
            let meta = index < metadata.count ? metadata[index] : PptxSlideMeta()
            let withImages = processor.replaceImages(
                in: chunk,
                imageCoords: meta.images,
                slideWidth: meta.width,
                slideHeight: meta.height
            )
            let withMeta = processor.appendSlideMeta(withImages, meta: meta)
            var body = "<!-- slide \(index + 1) of \(total) -->"
            if !withMeta.isEmpty {
                body += "\n\n\(withMeta)"
            }
            rendered.append(body)
            onPage?()
        }

        let noteCount = metadata.filter { !$0.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        let commentCount = metadata.reduce(0) { $0 + $1.comments.count }
        let header = TextTools.frontMatter(
            path: source,
            format: "pptx",
            extras: [
                ("converter", "pandoc \(pandoc.version)"),
                ("slides", String(metadata.isEmpty ? total : metadata.count)),
                ("notes", noteCount == 0 ? nil : String(noteCount)),
                ("comments", commentCount == 0 ? nil : String(commentCount)),
                ("images_ocr", options.useOCR ? ocr.label : "disabled"),
            ]
        )
        try TextTools.writeMarkdown("\(header)\n\n# \(TextTools.title(of: source))\n\n" + rendered.joined(separator: "\n\n"), to: output)
        return "pptx, \(metadata.isEmpty ? total : metadata.count) slide(s), \(noteCount) note(s), \(commentCount) comment(s)"
    }

    // MARK: - PDF

    private func convertPDF(_ source: URL, output: URL, onPage: PageHandler?, onOCR: OCRHandler?) throws -> String {
        let pipeline = PDFPipeline(
            helper: pdfHelper,
            ocr: ocr,
            cache: OCRCache(),
            useOCR: options.useOCR,
            onPage: onPage,
            onOCR: onOCR
        )
        return try pipeline.convert(source, to: output)
    }

    // MARK: - Queued batch pipeline

    private final class BatchProgressTracker {
        private let lock = NSLock()
        private let progress: ProgressHandler?
        private var state: WorkState
        private var imagesQueued = 0

        init(documentsTotal: Int, imagesTotal: Int, progress: ProgressHandler?) {
            state = WorkState(documentsTotal: documentsTotal, imagesTotal: imagesTotal)
            self.progress = progress
        }

        func start() {
            publish()
        }

        func addImages(_ count: Int) {
            guard count > 0 else { return }
            lock.lock()
            imagesQueued += count
            if state.imagesTotal < imagesQueued {
                state.imagesTotal = imagesQueued
            }
            let snapshot = state
            lock.unlock()
            progress?(.work(snapshot))
        }

        func imageFinished() {
            lock.lock()
            state.imagesDone += 1
            if state.imagesTotal < state.imagesDone {
                state.imagesTotal = state.imagesDone
            }
            let snapshot = state
            lock.unlock()
            progress?(.work(snapshot))
        }

        func documentFinished() {
            lock.lock()
            state.documentsDone += 1
            let snapshot = state
            lock.unlock()
            progress?(.work(snapshot))
        }

        func reconcile() {
            lock.lock()
            state.imagesTotal = state.imagesDone
            let snapshot = state
            lock.unlock()
            progress?(.work(snapshot))
        }

        private func publish() {
            lock.lock()
            let snapshot = state
            lock.unlock()
            progress?(.work(snapshot))
        }
    }

    private final class DocumentWork {
        let index: Int
        let source: URL
        let output: URL
        private let progress: BatchProgressTracker
        private let lock = NSLock()
        private var extractionDone = false
        private var pendingImages = 0
        private var didMarkDone = false
        private var errorMessage: String?
        var context: PreparedDocument?

        init(index: Int, source: URL, output: URL, progress: BatchProgressTracker) {
            self.index = index
            self.source = source
            self.output = output
            self.progress = progress
        }

        func addImages(_ count: Int) {
            guard count > 0 else { return }
            lock.lock()
            pendingImages += count
            lock.unlock()
            progress.addImages(count)
        }

        func imageFinished() {
            var finished = false
            lock.lock()
            pendingImages -= 1
            if !didMarkDone, extractionDone, pendingImages == 0 {
                didMarkDone = true
                finished = true
            }
            lock.unlock()
            progress.imageFinished()
            if finished {
                progress.documentFinished()
            }
        }

        func extractionFinished() {
            var finished = false
            lock.lock()
            extractionDone = true
            if !didMarkDone, pendingImages == 0 {
                didMarkDone = true
                finished = true
            }
            lock.unlock()
            if finished {
                progress.documentFinished()
            }
        }

        func fail(_ message: String) {
            var finished = false
            lock.lock()
            errorMessage = message
            extractionDone = true
            if !didMarkDone, pendingImages == 0 {
                didMarkDone = true
                finished = true
            }
            lock.unlock()
            if finished {
                progress.documentFinished()
            }
        }

        func failure() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return errorMessage
        }
    }

    private final class DocxContext {
        let temporary: TemporaryDirectory
        let mediaDir: URL
        let body: String
        let comments: [DocxComment]
        let header: String
        let processor: DocxImageProcessor

        init(
            temporary: TemporaryDirectory,
            mediaDir: URL,
            body: String,
            comments: [DocxComment],
            header: String,
            processor: DocxImageProcessor
        ) {
            self.temporary = temporary
            self.mediaDir = mediaDir
            self.body = body
            self.comments = comments
            self.header = header
            self.processor = processor
        }
    }

    private final class PptxContext {
        let temporary: TemporaryDirectory
        let mediaDir: URL
        let body: String
        let metadata: [PptxSlideMeta]
        let processor: PptxPostProcessor

        init(
            temporary: TemporaryDirectory,
            mediaDir: URL,
            body: String,
            metadata: [PptxSlideMeta],
            processor: PptxPostProcessor
        ) {
            self.temporary = temporary
            self.mediaDir = mediaDir
            self.body = body
            self.metadata = metadata
            self.processor = processor
        }
    }

    private final class PDFContext {
        let temporary: TemporaryDirectory
        let document: PDFDocument
        let cache: OCRCache

        init(temporary: TemporaryDirectory, document: PDFDocument, cache: OCRCache) {
            self.temporary = temporary
            self.document = document
            self.cache = cache
        }
    }

    private enum PreparedDocument {
        case docx(DocxContext)
        case pptx(PptxContext)
        case pdf(PDFContext)
    }

    private func prepareDOCX(
        _ source: URL,
        work: DocumentWork,
        queue: JobQueue
    ) throws -> DocxContext {
        let temporary = try TemporaryDirectory(prefix: "cp4ai_docx_")
        let body = try pandoc.convertDOCX(source, workdir: temporary.url)
        let mediaDir = temporary.url.appendingPathComponent("media")
        let cache = OCRCache()
        let processor = DocxImageProcessor(
            mediaDir: mediaDir,
            workdir: temporary.url,
            ocr: ocr,
            cache: cache,
            renderer: renderer,
            useOCR: options.useOCR,
            onOCR: nil
        )

        if options.useOCR {
            var urls = processor.collectImageURLs(in: body)
            urls.append(contentsOf: processor.mediaImageURLs())
            var seen = Set<String>()
            urls = urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
            work.addImages(urls.count)
            for url in urls {
                queue.add {
                    processor.preload(url)
                    work.imageFinished()
                }
            }
        }

        let comments = DocxMetadata.comments(at: source)
        let header = DocxMetadata.header(at: source)
        return DocxContext(
            temporary: temporary,
            mediaDir: mediaDir,
            body: body,
            comments: comments,
            header: header,
            processor: processor
        )
    }

    private func preparePPTX(
        _ source: URL,
        work: DocumentWork,
        queue: JobQueue
    ) throws -> PptxContext {
        let metadata = PptxMetadata.slides(at: source)
        let temporary = try TemporaryDirectory(prefix: "cp4ai_pptx_")
        let body = try pandoc.convertPPTX(source, workdir: temporary.url)
        let mediaDir = temporary.url.appendingPathComponent("media")
        let cache = OCRCache()
        let processor = PptxPostProcessor(
            mediaDir: mediaDir,
            workdir: temporary.url,
            ocr: ocr,
            cache: cache,
            renderer: renderer,
            useOCR: options.useOCR,
            onOCR: nil
        )

        if options.useOCR {
            let urls = processor.collectImageURLs(in: body)
            work.addImages(urls.count)
            for url in urls {
                queue.add {
                    processor.preload(url)
                    work.imageFinished()
                }
            }
        }

        return PptxContext(
            temporary: temporary,
            mediaDir: mediaDir,
            body: body,
            metadata: metadata,
            processor: processor
        )
    }

    private func preparePDF(
        _ source: URL,
        work: DocumentWork,
        queue: JobQueue
    ) throws -> PDFContext {
        let temporary = try TemporaryDirectory(prefix: "cp4ai_pdf_")
        let document = try pdfHelper.extract(source, output: temporary.url)
        let cache = OCRCache()

        if options.useOCR {
            for page in document.pages {
                for image in page.images {
                    work.addImages(1)
                    let file = temporary.url.appendingPathComponent(image.file)
                    queue.add { [weak self] in
                        guard let self else {
                            work.imageFinished()
                            return
                        }
                        if cache.text(for: image.sha256) == nil {
                            let text = (try? self.ocr.recognize(imageAt: file)) ?? ""
                            cache.store(text, for: image.sha256)
                        }
                        work.imageFinished()
                    }
                }
            }
        }

        return PDFContext(temporary: temporary, document: document, cache: cache)
    }

    private func assembleDOCX(_ context: DocxContext, source: URL, output: URL) throws -> String {
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var body = context.processor.replaceImages(in: context.body)
        let figures = context.processor.figuresSection()
        context.processor.addFailedVectors(figures.failed)
        let inserted = CommentPlacement.insert(markdown: body, comments: context.comments)
        body = inserted.markdown

        let front = TextTools.frontMatter(
            path: source,
            format: "docx",
            extras: [
                ("converter", "pandoc \(pandoc.version)"),
                ("header", context.header.isEmpty ? nil : context.header),
                ("comments", context.comments.isEmpty ? nil : String(context.comments.count)),
                ("images_ocr", options.useOCR ? ocr.label : "disabled"),
            ]
        )

        var pieces = [front, "", "# \(TextTools.title(of: source))", ""]
        if !context.header.isEmpty {
            pieces.append("> **Original document header:** \(context.header)")
            pieces.append("")
        }
        pieces.append(body)
        pieces.append("")
        pieces.append(figures.section)
        pieces.append(CommentPlacement.appendix(inserted.unplaced))
        pieces.append(context.processor.vectorNote())

        try TextTools.writeMarkdown(pieces.joined(separator: "\n"), to: output)
        return "docx, \(context.comments.count) comment(s), \(figures.count) floating figure(s), \(context.processor.failedVectorFiles().count) vector image(s) not OCR'd"
    }

    private func assemblePPTX(_ context: PptxContext, source: URL, output: URL) throws -> String {
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var split = context.processor.splitSlides(context.body)
        if !split.preamble.isEmpty, !split.chunks.isEmpty {
            split.chunks[0] = split.preamble + "\n\n" + split.chunks[0]
        } else if !split.preamble.isEmpty {
            split.chunks = [split.preamble]
        }

        let total = max(split.chunks.count, context.metadata.count)
        var rendered: [String] = []
        for index in 0..<total {
            let chunk = index < split.chunks.count ? split.chunks[index] : ""
            let meta = index < context.metadata.count ? context.metadata[index] : PptxSlideMeta()
            let withImages = context.processor.replaceImages(
                in: chunk,
                imageCoords: meta.images,
                slideWidth: meta.width,
                slideHeight: meta.height
            )
            let withMeta = context.processor.appendSlideMeta(withImages, meta: meta)
            var body = "<!-- slide \(index + 1) of \(total) -->"
            if !withMeta.isEmpty {
                body += "\n\n\(withMeta)"
            }
            rendered.append(body)
        }

        let noteCount = context.metadata.filter {
            !$0.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        let commentCount = context.metadata.reduce(0) { $0 + $1.comments.count }
        let header = TextTools.frontMatter(
            path: source,
            format: "pptx",
            extras: [
                ("converter", "pandoc \(pandoc.version)"),
                ("slides", String(context.metadata.isEmpty ? total : context.metadata.count)),
                ("notes", noteCount == 0 ? nil : String(noteCount)),
                ("comments", commentCount == 0 ? nil : String(commentCount)),
                ("images_ocr", options.useOCR ? ocr.label : "disabled"),
            ]
        )
        try TextTools.writeMarkdown(
            "\(header)\n\n# \(TextTools.title(of: source))\n\n" + rendered.joined(separator: "\n\n"),
            to: output
        )
        return "pptx, \(context.metadata.isEmpty ? total : context.metadata.count) slide(s), \(noteCount) note(s), \(commentCount) comment(s)"
    }

    private func assemblePDF(_ context: PDFContext, source: URL, output: URL) throws -> String {
        let pipeline = PDFPipeline(
            helper: pdfHelper,
            ocr: ocr,
            cache: context.cache,
            useOCR: options.useOCR,
            onPage: nil,
            onOCR: nil
        )
        return try pipeline.convert(
            document: context.document,
            regionsDirectory: context.temporary.url,
            source: source,
            to: output
        )
    }

}
