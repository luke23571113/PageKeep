import Foundation
import PDFKit
import Darwin

actor LibraryRepository {
    enum Checkpoint: Sendable {
        case afterCandidatePDF
        case beforeBackup
        case afterBackup
        case beforeManifestCommit
        case beforeInitialInstall
    }

    nonisolated static var defaultApplicationSupportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PageKeep", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
    }

    nonisolated let rootURL: URL
    private let failureInjector: (@Sendable (Checkpoint) throws -> Void)?
    private let startedAt = Date()
    private var manifest: LibraryManifest?
    private let fileManager = FileManager.default

    init(
        rootURL: URL = LibraryRepository.defaultApplicationSupportRoot,
        failureInjector: (@Sendable (Checkpoint) throws -> Void)? = nil
    ) {
        self.rootURL = rootURL
        self.failureInjector = failureInjector
    }

    nonisolated func pdfURL(for notebook: Notebook) -> URL? {
        guard let revisionID = notebook.revisionID else { return nil }
        return rootURL.appendingPathComponent("PDFs", isDirectory: true)
            .appendingPathComponent("\(revisionID.uuidString).pdf")
    }

    func load() throws -> LibrarySnapshot {
        manifest = nil
        if !fileManager.fileExists(atPath: rootURL.path) {
            try installInitialLibrary()
        }
        let current = try readManifest(at: currentURL)
        // A future backup may belong to a newer app as well. Leave the store untouched.
        let backup = try validatedBackupIfPresent()
        manifest = current
        let snapshot = snapshot(for: current)
        TemporaryPDFCleanup.cleanOnce(before: startedAt)
        let backupHasErrors = backup.map { !self.snapshot(for: $0).notebookErrors.isEmpty } ?? false
        if snapshot.notebookErrors.isEmpty, !backupHasErrors,
           backup != nil || !fileManager.fileExists(atPath: backupURL.path) {
            cleanUnusedPDFs(current: current, backup: backup)
        }
        return snapshot
    }

    func canRecover() -> Bool {
        guard fileManager.fileExists(atPath: currentURL.path) else {
            return completeBackup() != nil
        }
        do {
            _ = try readManifest(at: currentURL)
            return false
        } catch LibraryError.newerSchema {
            return false
        } catch {
            return completeBackup() != nil
        }
    }

    func recover() throws -> LibrarySnapshot {
        guard canRecover(), let recovered = completeBackup() else {
            throw LibraryError.recoveryUnavailable
        }
        let data = try encode(recovered)
        try Task.checkCancellation()
        try atomicWrite(data, to: currentURL)
        manifest = recovered
        return snapshot(for: recovered)
    }

    func prepareImport(from sourceURL: URL) throws -> PreparedPDF {
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let url = try PDFService.makeStagingURL()
        do {
            try Task.checkCancellation()
            try coordinatedCopy(from: sourceURL, to: url)
            let document = try PDFService.validate(at: url)
            try Task.checkCancellation()
            return PreparedPDF(
                url: url,
                suggestedName: sourceURL.deletingPathExtension().lastPathComponent,
                pageCount: document.pageCount
            )
        } catch {
            try? fileManager.removeItem(at: url.deletingLastPathComponent())
            throw error
        }
    }

    func discardPrepared(_ prepared: PreparedPDF) {
        PDFService.discard(prepared)
    }

    func create(id: UUID, name: String, from prepared: PreparedPDF) throws -> LibrarySnapshot {
        var next = try loadedManifest()
        guard !next.notebooks.contains(where: { $0.id == id }) else { throw LibraryError.invalidChange }
        let document = try preparedDocument(prepared)
        let date = Date()
        var notebook = Notebook(
            id: id,
            name: try validName(name),
            createdAt: date,
            modifiedAt: date,
            revisionID: nil,
            pages: (0..<document.pageCount).map { _ in NotebookPage() }
        )
        notebook.revisionID = try saveCandidateCopy(from: prepared.url)
        next.notebooks.append(notebook)
        return try commit(next)
    }

    func append(to id: UUID, from prepared: PreparedPDF) throws -> LibrarySnapshot {
        var next = try loadedManifest()
        let index = try notebookIndex(id, in: next)
        let document = try document(for: next.notebooks[index])
        let incoming = try preparedDocument(prepared)
        for pageIndex in 0..<incoming.pageCount {
            guard let page = incoming.page(at: pageIndex)?.copy() as? PDFPage else { throw PDFError.invalidDocument }
            document.insert(page, at: document.pageCount)
            next.notebooks[index].pages.append(NotebookPage())
        }
        try updatePDF(document, notebook: &next.notebooks[index])
        return try commit(next)
    }

    func rename(_ id: UUID, to name: String) throws -> LibrarySnapshot {
        var next = try loadedManifest()
        let index = try notebookIndex(id, in: next)
        let name = try validName(name)
        guard next.notebooks[index].name != name else { return snapshot(for: next) }
        next.notebooks[index].name = name
        next.notebooks[index].modifiedAt = Date()
        return try commit(next)
    }

    func deleteNotebook(_ id: UUID) throws -> LibrarySnapshot {
        var next = try loadedManifest()
        let index = try notebookIndex(id, in: next)
        next.notebooks.remove(at: index)
        return try commit(next)
    }

    func reorderPages(in id: UUID, orderedIDs: [UUID]) throws -> LibrarySnapshot {
        var next = try loadedManifest()
        let index = try notebookIndex(id, in: next)
        let notebook = next.notebooks[index]
        guard orderedIDs.count == notebook.pages.count,
              Set(orderedIDs).count == orderedIDs.count,
              Set(orderedIDs) == Set(notebook.pages.map(\.id)) else {
            throw LibraryError.invalidChange
        }
        guard orderedIDs != notebook.pages.map(\.id) else { return snapshot(for: next) }
        let source = try document(for: notebook)
        let reordered = PDFDocument()
        reordered.documentAttributes = source.documentAttributes
        for pageID in orderedIDs {
            guard let oldIndex = notebook.pages.firstIndex(where: { $0.id == pageID }),
                  let page = source.page(at: oldIndex)?.copy() as? PDFPage else { throw PDFError.invalidDocument }
            reordered.insert(page, at: reordered.pageCount)
        }
        next.notebooks[index].pages = orderedIDs.map { NotebookPage(id: $0) }
        try updatePDF(reordered, notebook: &next.notebooks[index])
        return try commit(next)
    }

    func rotatePages(in id: UUID, ids: Set<UUID>) throws -> LibrarySnapshot {
        var next = try loadedManifest()
        let index = try notebookIndex(id, in: next)
        try validateSelection(ids, notebook: next.notebooks[index])
        guard !ids.isEmpty else { return snapshot(for: next) }
        let document = try document(for: next.notebooks[index])
        for (pageIndex, pageInfo) in next.notebooks[index].pages.enumerated() where ids.contains(pageInfo.id) {
            guard let page = document.page(at: pageIndex) else { throw PDFError.invalidDocument }
            // Positive PDF /Rotate values turn the displayed page clockwise.
            page.rotation = (page.rotation + 90) % 360
        }
        try updatePDF(document, notebook: &next.notebooks[index])
        return try commit(next)
    }

    func deletePages(in id: UUID, ids: Set<UUID>) throws -> LibrarySnapshot {
        var next = try loadedManifest()
        let index = try notebookIndex(id, in: next)
        try validateSelection(ids, notebook: next.notebooks[index])
        guard !ids.isEmpty else { return snapshot(for: next) }
        let document = try document(for: next.notebooks[index])
        for pageIndex in next.notebooks[index].pages.indices.reversed()
            where ids.contains(next.notebooks[index].pages[pageIndex].id) {
            document.removePage(at: pageIndex)
        }
        next.notebooks[index].pages.removeAll { ids.contains($0.id) }
        try updatePDF(document, notebook: &next.notebooks[index])
        return try commit(next)
    }

    func shareCopy(of id: UUID) throws -> URL {
        let current = try loadedManifest()
        let notebook = current.notebooks[try notebookIndex(id, in: current)]
        guard !notebook.pages.isEmpty else { throw LibraryError.emptyNotebook }
        _ = try document(for: notebook)
        guard let source = pdfURL(for: notebook) else { throw LibraryError.missingPDF }
        let folder = fileManager.temporaryDirectory.appendingPathComponent("PageKeep-Share", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(shareFileName(notebook.name)).appendingPathExtension("pdf")
        do {
            try Task.checkCancellation()
            try fileManager.copyItem(at: source, to: destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }

    private var currentURL: URL { rootURL.appendingPathComponent("manifest.json") }
    private var backupURL: URL { rootURL.appendingPathComponent("manifest.backup.json") }
    private var pdfFolder: URL { rootURL.appendingPathComponent("PDFs", isDirectory: true) }

    private func loadedManifest() throws -> LibraryManifest {
        if manifest == nil { _ = try load() }
        guard let manifest else { throw LibraryError.damagedManifest }
        return manifest
    }

    private func readManifest(at url: URL) throws -> LibraryManifest {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw LibraryError.damagedManifest }
        // Read the version separately so a newer format is never mistaken for corruption.
        struct Version: Decodable { let schemaVersion: Int }
        if let version = try? JSONDecoder().decode(Version.self, from: data), version.schemaVersion > 1 {
            throw LibraryError.newerSchema
        }
        guard let decoded = try? JSONDecoder().decode(LibraryManifest.self, from: data),
              decoded.schemaVersion == 1, decoded.initialized else { throw LibraryError.damagedManifest }
        guard Set(decoded.notebooks.map(\.id)).count == decoded.notebooks.count else {
            throw LibraryError.damagedManifest
        }
        var revisions = Set<UUID>()
        for notebook in decoded.notebooks {
            guard !notebook.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  Set(notebook.pages.map(\.id)).count == notebook.pages.count,
                  notebook.pages.isEmpty == (notebook.revisionID == nil) else {
                throw LibraryError.damagedManifest
            }
            if let revision = notebook.revisionID, !revisions.insert(revision).inserted {
                throw LibraryError.damagedManifest
            }
        }
        return decoded
    }

    private func validatedBackupIfPresent() throws -> LibraryManifest? {
        guard fileManager.fileExists(atPath: backupURL.path) else { return nil }
        do { return try readManifest(at: backupURL) }
        catch LibraryError.newerSchema { throw LibraryError.newerSchema }
        catch { return nil }
    }

    private func completeBackup() -> LibraryManifest? {
        guard let backup = try? readManifest(at: backupURL), snapshot(for: backup).notebookErrors.isEmpty else { return nil }
        return backup
    }

    private func snapshot(for manifest: LibraryManifest) -> LibrarySnapshot {
        var errors: [UUID: String] = [:]
        for notebook in manifest.notebooks where !notebook.pages.isEmpty {
            do { _ = try document(for: notebook) }
            catch { errors[notebook.id] = error.localizedDescription }
        }
        return LibrarySnapshot(manifest: manifest, notebookErrors: errors)
    }

    private func document(for notebook: Notebook) throws -> PDFDocument {
        guard !notebook.pages.isEmpty else { return PDFDocument() }
        guard let url = pdfURL(for: notebook), fileManager.fileExists(atPath: url.path) else {
            throw LibraryError.missingPDF
        }
        let document = try PDFService.validate(at: url)
        guard document.pageCount == notebook.pageCount else { throw LibraryError.pageCountMismatch }
        return document
    }

    private func preparedDocument(_ prepared: PreparedPDF) throws -> PDFDocument {
        let document = try PDFService.validate(at: prepared.url)
        guard document.pageCount == prepared.pageCount else { throw LibraryError.pageCountMismatch }
        return document
    }

    private func notebookIndex(_ id: UUID, in manifest: LibraryManifest) throws -> Int {
        guard let index = manifest.notebooks.firstIndex(where: { $0.id == id }) else { throw LibraryError.notebookNotFound }
        return index
    }

    private func validName(_ name: String) throws -> String {
        let result = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw LibraryError.emptyName }
        return result
    }

    private func shareFileName(_ name: String) -> String {
        let sanitized = name.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters))
            .joined(separator: "-")
        var result = ""
        for character in sanitized {
            guard result.utf8.count + String(character).utf8.count <= 180 else { break }
            result.append(character)
        }
        return result.isEmpty ? "Notebook" : result
    }

    private func validateSelection(_ ids: Set<UUID>, notebook: Notebook) throws {
        guard ids.isSubset(of: Set(notebook.pages.map(\.id))) else { throw LibraryError.invalidChange }
    }

    private func updatePDF(_ document: PDFDocument, notebook: inout Notebook) throws {
        notebook.revisionID = document.pageCount == 0 ? nil : try saveCandidate(document)
        notebook.modifiedAt = Date()
    }

    private func coordinatedCopy(from source: URL, to destination: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var copyError: Error?
        coordinator.coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readableURL in
            do { try fileManager.copyItem(at: readableURL, to: destination) }
            catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        guard fileManager.fileExists(atPath: destination.path) else { throw PDFError.invalidDocument }
    }

    private func saveCandidateCopy(from source: URL) throws -> UUID {
        try Task.checkCancellation()
        let revision = UUID()
        let temporary = pdfFolder.appendingPathComponent("\(revision.uuidString).pending")
        let destination = pdfFolder.appendingPathComponent("\(revision.uuidString).pdf")
        do {
            try fileManager.copyItem(at: source, to: temporary)
            _ = try PDFService.validate(at: temporary)
            try Task.checkCancellation()
            try moveAtomically(from: temporary, to: destination)
            try failureInjector?(.afterCandidatePDF)
            return revision
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func saveCandidate(_ document: PDFDocument) throws -> UUID {
        try Task.checkCancellation()
        let revision = UUID()
        let temporary = pdfFolder.appendingPathComponent("\(revision.uuidString).pending")
        let destination = pdfFolder.appendingPathComponent("\(revision.uuidString).pdf")
        do {
            try PDFService.write(document, to: temporary)
            try Task.checkCancellation()
            try moveAtomically(from: temporary, to: destination)
            try failureInjector?(.afterCandidatePDF)
            return revision
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func commit(_ next: LibraryManifest) throws -> LibrarySnapshot {
        let data = try encode(next)
        let previous = try Data(contentsOf: currentURL)
        try failureInjector?(.beforeBackup)
        try Task.checkCancellation()
        try atomicWrite(previous, to: backupURL)
        try failureInjector?(.afterBackup)
        try failureInjector?(.beforeManifestCommit)
        try Task.checkCancellation()
        try atomicWrite(data, to: currentURL)
        // Nothing after the atomic commit may turn a successful save into a reported failure.
        manifest = next
        return snapshot(for: next)
    }

    private func encode(_ manifest: LibraryManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(manifest)
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).pending")
        do {
            try data.write(to: temporary)
            try Task.checkCancellation()
            try moveAtomically(from: temporary, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func moveAtomically(from source: URL, to destination: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                Darwin.rename(sourcePath!, destinationPath!)
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func installInitialLibrary() throws {
        let parent = rootURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".PageKeep-\(UUID().uuidString)", isDirectory: true)
        do {
            let stagedPDFs = staging.appendingPathComponent("PDFs", isDirectory: true)
            try fileManager.createDirectory(at: stagedPDFs, withIntermediateDirectories: true)
            let revision = UUID()
            try PDFService.writeSample(to: stagedPDFs.appendingPathComponent("\(revision.uuidString).pdf"))
            let date = Date()
            let sample = Notebook(
                id: UUID(), name: "Welcome to PageKeep", createdAt: date, modifiedAt: date,
                revisionID: revision, pages: (0..<3).map { _ in NotebookPage() }
            )
            let initial = try encode(LibraryManifest(notebooks: [sample]))
            try initial.write(to: staging.appendingPathComponent("manifest.json"))
            try initial.write(to: staging.appendingPathComponent("manifest.backup.json"))
            try failureInjector?(.beforeInitialInstall)
            try Task.checkCancellation()
            try moveAtomically(from: staging, to: rootURL)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private func cleanUnusedPDFs(current: LibraryManifest, backup: LibraryManifest?) {
        let referenced = Set((current.notebooks + (backup?.notebooks ?? [])).compactMap(\.revisionID).map { "\($0.uuidString).pdf" })
        guard let files = try? fileManager.contentsOfDirectory(at: pdfFolder, includingPropertiesForKeys: nil) else { return }
        for file in files where !referenced.contains(file.lastPathComponent) {
            if file.pathExtension == "pdf" || file.pathExtension == "pending" {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}

private enum TemporaryPDFCleanup {
    static let lock = NSLock()
    static var didClean = false

    static func cleanOnce(before startup: Date) {
        lock.lock()
        defer { lock.unlock() }
        guard !didClean else { return }
        didClean = true
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey]
        for name in ["PageKeep-Staging", "PageKeep-Share"] {
            let root = manager.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
            guard let rootValues = try? root.resourceValues(forKeys: keys),
                  rootValues.isSymbolicLink != true,
                  let folders = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)) else { continue }
            for folder in folders {
                guard UUID(uuidString: folder.lastPathComponent) != nil,
                      let values = try? folder.resourceValues(forKeys: keys),
                      values.isDirectory == true, values.isSymbolicLink != true,
                      let createdAt = values.creationDate, createdAt < startup else { continue }
                try? manager.removeItem(at: folder)
            }
        }
    }
}

enum LibraryError: LocalizedError {
    case damagedManifest
    case newerSchema
    case recoveryUnavailable
    case notebookNotFound
    case missingPDF
    case pageCountMismatch
    case emptyName
    case emptyNotebook
    case invalidChange

    var errorDescription: String? {
        switch self {
        case .damagedManifest: "The notebook library could not be read. Your saved files have been kept."
        case .newerSchema: "This library was saved by a newer version of PageKeep. Update the app to open it."
        case .recoveryUnavailable: "A complete library backup is not available."
        case .notebookNotFound: "This notebook could not be found."
        case .missingPDF: "The saved PDF is missing. You can delete this notebook or restore its file from a device backup."
        case .pageCountMismatch: "The saved PDF does not match this notebook's page list."
        case .emptyName: "Enter a notebook name."
        case .emptyNotebook: "Add pages before sharing this notebook."
        case .invalidChange: "The page selection has changed. Open the notebook again and retry."
        }
    }
}
