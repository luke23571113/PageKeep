import Foundation
import PDFKit
import CoreGraphics
import CoreText

// PDFKit keeps imported text, vectors, and annotations as PDF content.
enum PDFService {
    static var stagingRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PageKeep-Staging", isDirectory: true)
    }

    static func makeStagingURL() throws -> URL {
        let folder = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("document.pdf")
    }

    static func validate(at url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw PDFError.invalidDocument
        }
        guard !document.isEncrypted, !document.isLocked else {
            throw PDFError.encryptedDocument
        }
        guard document.pageCount > 0 else {
            throw PDFError.emptyDocument
        }
        guard document.allowsCopying, document.allowsDocumentAssembly else {
            throw PDFError.restrictedDocument
        }
        for index in 0..<document.pageCount {
            guard document.page(at: index) != nil else {
                throw PDFError.invalidDocument
            }
        }
        return document
    }

    static func write(_ document: PDFDocument, to url: URL) throws {
        guard document.pageCount > 0 else { throw PDFError.emptyDocument }
        guard document.write(to: url) else { throw PDFError.writeFailed }
        let saved = try validate(at: url)
        guard saved.pageCount == document.pageCount else { throw PDFError.writeFailed }
    }

    static func discard(_ prepared: PreparedPDF) {
        let folder = prepared.url.deletingLastPathComponent().standardizedFileURL
        guard folder.deletingLastPathComponent() == stagingRoot.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    static func writeSample(to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw PDFError.writeFailed
        }
        let content = [
            ("Welcome to PageKeep", "Your paper pages, together.\n\nScan pages or import a PDF to start a notebook.\nThis sample has three real PDF pages to explore."),
            ("Keep pages in order", "Open a notebook to read its pages.\n\nUse Manage Pages to reorder, rotate, or delete pages.\nAdd more pages whenever you need them."),
            ("Take your notes with you", "Share a whole notebook as a PDF.\n\nYour notebooks stay on this device.\nYou can rename or delete this sample at any time.")
        ]
        for (index, page) in content.enumerated() {
            context.beginPDFPage(nil)
            context.setStrokeColor(CGColor(gray: 0.78, alpha: 1))
            context.setLineWidth(1)
            for row in 0..<15 {
                let y = CGFloat(100 + row * 28)
                context.move(to: CGPoint(x: 54, y: y))
                context.addLine(to: CGPoint(x: 558, y: y))
            }
            context.strokePath()
            drawText(page.0, size: 26, in: CGRect(x: 54, y: 640, width: 504, height: 80), context: context)
            drawText(page.1, size: 16, in: CGRect(x: 54, y: 380, width: 504, height: 220), context: context)
            drawText("\(index + 1)", size: 12, in: CGRect(x: 54, y: 35, width: 504, height: 24), context: context)
            context.endPDFPage()
        }
        context.closePDF()
        _ = try validate(at: url)
    }

    private static func drawText(_ text: String, size: CGFloat, in rect: CGRect, context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.15, alpha: 1)
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
    }
}

enum PDFError: LocalizedError {
    case invalidDocument
    case encryptedDocument
    case emptyDocument
    case restrictedDocument
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidDocument: "This file could not be opened as a PDF."
        case .encryptedDocument: "Password-protected PDFs are not supported."
        case .emptyDocument: "This PDF does not contain any pages."
        case .restrictedDocument: "This PDF does not allow copying or page changes."
        case .writeFailed: "The PDF could not be saved."
        }
    }
}
