import Foundation

public struct PDFImagePlacement: Decodable {
    public let file: String
    public let bbox: [Double]
    public let sha256: String
    public let kind: String
    public let width: Int
    public let height: Int
}

public struct PDFPage: Decodable {
    public let number: Int
    public let markdown: String
    public let width: Double
    public let height: Double
    public let images: [PDFImagePlacement]
}

public struct PDFDocument: Decodable {
    public let schema: Int
    public let pymupdf: String
    public let pageCount: Int
    public let pages: [PDFPage]
}

public struct PDFProbePage: Decodable {
    public let number: Int
    public let images: Int
}

public struct PDFProbe: Decodable {
    public let schema: Int
    public let pymupdf: String
    public let pageCount: Int
    public let ocrJobs: Int
    public let pages: [PDFProbePage]
}

public final class PDFHelperClient {
    private let resources: CP4AIResources

    public init(resources: CP4AIResources) {
        self.resources = resources
    }

    public func probe(_ url: URL) throws -> PDFProbe {
        let output = try run(["probe", "--input", url.standardizedFileURL.path])
        let probe = try decode(PDFProbe.self, from: output)
        guard probe.schema == 2 else {
            throw ConversionError.invalidDocument("unsupported PDF helper schema: \(probe.schema)")
        }
        return probe
    }

    public func extract(_ url: URL, output: URL) throws -> PDFDocument {
        let result = try run([
            "extract",
            "--input", url.standardizedFileURL.path,
            "--output", output.path,
        ])
        let document = try decode(PDFDocument.self, from: result)
        guard document.schema == 2 else {
            throw ConversionError.invalidDocument("unsupported PDF helper schema: \(document.schema)")
        }
        return document
    }

    private func run(_ arguments: [String]) throws -> String {
        guard let helper = resources.pdfHelper else {
            throw ConversionError.missingTool(
                "the bundled PDF helper is missing from this copy of Copy 4 AI. "
                    + "Reinstall the app, or build it with "
                    + "packaging/build_pdf_helper.sh in a development checkout. "
                    + "Resources: \(resources.root.path)"
            )
        }
        let process = try ProcessRunner.run(helper, arguments)
        guard process.succeeded else {
            throw ConversionError.processFailed(
                "PDF helper failed: \(process.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        return process.stdout
    }

    private func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = text.data(using: .utf8) else {
            throw ConversionError.invalidDocument("PDF helper returned invalid UTF-8")
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            let preview = text.prefix(300)
            throw ConversionError.invalidDocument(
                "could not parse PDF helper output: \(error.localizedDescription)\n\(preview)"
            )
        }
    }
}
