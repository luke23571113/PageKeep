import Foundation
import PDFKit
import UIKit

actor ScanProcessor {
    func prepare(_ capture: CapturedScan) throws -> PreparedPDF {
        try prepare(pageCount: capture.scan.pageCount) { index in
            capture.scan.imageOfPage(at: index)
        }
    }

    func prepare(pageCount: Int, imageAt: (Int) throws -> UIImage) throws -> PreparedPDF {
        guard pageCount > 0 else { throw ScanError.noPages }
        let url = try PDFService.makeStagingURL()
        let folder = url.deletingLastPathComponent()
        do {
            let document = PDFDocument()
            var pageDocuments: [PDFDocument] = []
            var pageURLs: [URL] = []
            for index in 0..<pageCount {
                try Task.checkCancellation()
                let pageURL = folder.appendingPathComponent("page-\(index).pdf")
                // Release each full-size scan before asking the scanner for the next one.
                try autoreleasepool {
                    let image = try imageAt(index)
                    guard let page = PDFPage(image: image, options: [.compressionQuality: 0.95]) else {
                        throw ScanError.pageCreation
                    }
                    let singlePage = PDFDocument()
                    singlePage.insert(page, at: 0)
                    try PDFService.write(singlePage, to: pageURL)
                }
                let pageDocument = try PDFService.validate(at: pageURL)
                guard let page = pageDocument.page(at: 0)?.copy() as? PDFPage else {
                    throw ScanError.pageCreation
                }
                document.insert(page, at: document.pageCount)
                pageDocuments.append(pageDocument)
                pageURLs.append(pageURL)
            }
            try Task.checkCancellation()
            try withExtendedLifetime(pageDocuments) {
                try PDFService.write(document, to: url)
            }
            for pageURL in pageURLs {
                try? FileManager.default.removeItem(at: pageURL)
            }
            try Task.checkCancellation()
            return PreparedPDF(url: url, suggestedName: "Untitled Notebook", pageCount: document.pageCount)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}

private enum ScanError: LocalizedError {
    case noPages
    case pageCreation

    var errorDescription: String? {
        switch self {
        case .noPages: "The scan did not contain any pages. Please scan again."
        case .pageCreation: "A scanned page could not be prepared. Please try again."
        }
    }
}
