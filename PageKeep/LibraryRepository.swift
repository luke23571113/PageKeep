import Foundation
import PDFKit

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
    private let files: LibraryFiles

    init(
        rootURL: URL = LibraryRepository.defaultApplicationSupportRoot,
        failureInjector: (@Sendable (Checkpoint) throws -> Void)? = nil
    ) {
        self.rootURL = rootURL
        files = LibraryFiles(rootURL: rootURL)
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
        let current = try files.readManifest(at: files.currentURL)
        // A future backup may belong to a newer app as well. Leave the store untouched.
        let backup = try validatedBackupIfPresent()
        manifest = current
        let snapshot = snapshot(for: current)
        TemporaryPDFCleanup.cleanOnce(before: startedAt)
        let backupHasErrors = backup.map { !self.snapshot(for: $0).notebookErrors.isEmpty } ?? false
        if snapshot.notebookErrors.isEmpty, !backupHasErrors,
           backup != nil || !fileManager.fileExists(atPath: files.backupURL.path) {
            cleanUnusedPDFs(current: current, backup: backup)
        }
        return snapshot
    }

    func canRecover() -> Bool {
        guard fileManager.fileExists(atPath: files.currentURL.path) else {
            return completeBackup() != nil
        }
        do {
            _ = try files.readManifest(at: files.currentURL)
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
        let data = try Data(contentsOf: files.backupURL)
        try Task.checkCancellation()
        try files.atomicWrite(data, to: files.currentURL)
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
            try files.coordinatedCopy(from: sourceURL, to: url)
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

    func create(
        id: UUID, details: NotebookDetails, from additions: [PreparedPDF], pageLayout: [DraftPage]? = nil
    ) throws -> LibrarySnapshot {
        var next = try loadedManifest()
        guard !next.notebooks.contains(where: { $0.id == id }) else { throw LibraryError.invalidChange }
        guard !additions.isEmpty else { throw PDFError.emptyDocument }
        let name = try NotebookNaming.resolvedName(details.name, in: next.notebooks)
        let documents = try additions.map { try preparedDocument($0) }
        let date = Date()
        var notebook = Notebook(
            id: id, name: name, createdAt: date, modifiedAt: date,
            revisionID: nil, pages: [], symbolName: details.symbolName, colorID: details.colorID
        )
        if let pageLayout {
            guard !pageLayout.isEmpty else { throw PDFError.emptyDocument }
            let combined = try PDFPageComposition.arrangedDocument(pageLayout, existingNotebook: nil, existingDocument: nil, additions: additions, documents: documents)
            notebook.pages = pageLayout.map { NotebookPage(id: $0.id) }
            try updatePDF(combined, notebook: &notebook)
        } else if let single = additions.first, additions.count == 1 {
            notebook.pages = (0..<single.pageCount).map { _ in NotebookPage() }
            notebook.revisionID = try saveCandidateCopy(from: single.url)
        } else if !documents.isEmpty {
            let combined = PDFDocument()
            combined.documentAttributes = documents.first?.documentAttributes
            try PDFPageComposition.append(documents, to: combined, notebook: &notebook)
            try updatePDF(combined, notebook: &notebook)
        }
        next.notebooks.insert(notebook, at: 0)
        return try commit(next)
    }

    func edit(
        _ id: UUID, details: NotebookDetails, appending additions: [PreparedPDF],
        pageLayout: [DraftPage]? = nil, expectedExistingPageIDs: [UUID]? = nil
    ) throws -> LibrarySnapshot {
        var next = try loadedManifest()
        let index = try notebookIndex(id, in: next)
        let name = try NotebookNaming.resolvedName(details.name, in: next.notebooks, excluding: id)
        let original = next.notebooks[index]
        if pageLayout != nil, let expectedExistingPageIDs, expectedExistingPageIDs != original.pages.map(\.id) {
            throw LibraryError.invalidChange
        }
        next.notebooks[index].name = name
        next.notebooks[index].symbolName = details.symbolName
        next.notebooks[index].colorID = details.colorID
        if let pageLayout {
            let documents = try additions.map { try preparedDocument($0) }
            let arranged = try PDFPageComposition.arrangedDocument(pageLayout, existingNotebook: original, existingDocument: document(for: original), additions: additions, documents: documents)
            let originalLayout = original.pages.map { DraftPage(id: $0.id, source: .existing($0.id)) }
            if pageLayout != originalLayout {
                next.notebooks[index].pages = pageLayout.map { NotebookPage(id: $0.id) }
                try updatePDF(arranged, notebook: &next.notebooks[index])
            } else {
                guard original != next.notebooks[index] else { return snapshot(for: next) }
                next.notebooks[index].modifiedAt = Date()
            }
        } else if !additions.isEmpty {
            // Validate every batch before creating a candidate or changing the manifest.
            let documents = try additions.map { try preparedDocument($0) }
            let document = try document(for: original)
            try PDFPageComposition.append(documents, to: document, notebook: &next.notebooks[index])
            try updatePDF(document, notebook: &next.notebooks[index])
        } else {
            guard original != next.notebooks[index] else { return snapshot(for: next) }
            next.notebooks[index].modifiedAt = Date()
        }
        return try commit(next)
    }

    func reorderNotebooks(orderedActiveIDs: [UUID]) throws -> LibrarySnapshot {
        var next = try loadedManifest()
        let active = next.notebooks.filter { !$0.isArchived }
        guard orderedActiveIDs.count == active.count,
              Set(orderedActiveIDs).count == orderedActiveIDs.count,
              Set(orderedActiveIDs) == Set(active.map(\.id)) else { throw LibraryError.invalidChange }
        guard orderedActiveIDs != active.map(\.id) else { return snapshot(for: next) }
        let byID = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0) })
        var position = 0
        for index in next.notebooks.indices where !next.notebooks[index].isArchived {
            guard let notebook = byID[orderedActiveIDs[position]] else { throw LibraryError.invalidChange }
            next.notebooks[index] = notebook
            position += 1
        }
        return try commit(next)
    }

    func setArchived(_ archived: Bool, ids: Set<UUID>) throws -> LibrarySnapshot {
        var next = try loadedManifest()
        guard ids.isSubset(of: Set(next.notebooks.map(\.id))) else { throw LibraryError.invalidChange }
        var changed = false
        for index in next.notebooks.indices where ids.contains(next.notebooks[index].id) {
            if next.notebooks[index].isArchived != archived {
                next.notebooks[index].isArchived = archived
                next.notebooks[index].modifiedAt = Date()
                changed = true
            }
        }
        guard changed else { return snapshot(for: next) }
        return try commit(next)
    }

    func append(to id: UUID, from prepared: PreparedPDF) throws -> LibrarySnapshot {
        var next = try loadedManifest()
        let index = try notebookIndex(id, in: next)
        let incoming = try preparedDocument(prepared)
        let document = try document(for: next.notebooks[index])
        try PDFPageComposition.append([incoming], to: document, notebook: &next.notebooks[index])
        try updatePDF(document, notebook: &next.notebooks[index])
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
        let indices = Dictionary(uniqueKeysWithValues: notebook.pages.enumerated().map { ($0.element.id, $0.offset) })
        for pageID in orderedIDs {
            try Task.checkCancellation()
            guard let oldIndex = indices[pageID],
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
        let destination = folder.appendingPathComponent(files.shareFileName(notebook.name)).appendingPathExtension("pdf")
        do {
            try Task.checkCancellation()
            try fileManager.copyItem(at: source, to: destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }

    private func loadedManifest() throws -> LibraryManifest {
        if manifest == nil { _ = try load() }
        guard let manifest else { throw LibraryError.damagedManifest }
        return manifest
    }

    private func validatedBackupIfPresent() throws -> LibraryManifest? {
        guard fileManager.fileExists(atPath: files.backupURL.path) else { return nil }
        do { return try files.readManifest(at: files.backupURL) }
        catch LibraryError.newerSchema { throw LibraryError.newerSchema }
        catch { return nil }
    }

    private func completeBackup() -> LibraryManifest? {
        guard let backup = try? files.readManifest(at: files.backupURL), snapshot(for: backup).notebookErrors.isEmpty else { return nil }
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

    private func validateSelection(_ ids: Set<UUID>, notebook: Notebook) throws {
        guard ids.isSubset(of: Set(notebook.pages.map(\.id))) else { throw LibraryError.invalidChange }
    }

    private func updatePDF(_ document: PDFDocument, notebook: inout Notebook) throws {
        notebook.revisionID = document.pageCount == 0 ? nil : try saveCandidate(document)
        notebook.modifiedAt = Date()
    }

    private func saveCandidateCopy(from source: URL) throws -> UUID {
        try Task.checkCancellation()
        let revision = UUID()
        let temporary = files.pdfFolder.appendingPathComponent("\(revision.uuidString).pending")
        let destination = files.pdfFolder.appendingPathComponent("\(revision.uuidString).pdf")
        do {
            try fileManager.copyItem(at: source, to: temporary)
            _ = try PDFService.validate(at: temporary)
            try Task.checkCancellation()
            try files.moveAtomically(from: temporary, to: destination)
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
        let temporary = files.pdfFolder.appendingPathComponent("\(revision.uuidString).pending")
        let destination = files.pdfFolder.appendingPathComponent("\(revision.uuidString).pdf")
        do {
            try PDFService.write(document, to: temporary)
            try Task.checkCancellation()
            try files.moveAtomically(from: temporary, to: destination)
            try failureInjector?(.afterCandidatePDF)
            return revision
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func commit(_ next: LibraryManifest) throws -> LibrarySnapshot {
        let data = try files.encode(next)
        let previous = try Data(contentsOf: files.currentURL)
        try failureInjector?(.beforeBackup)
        try Task.checkCancellation()
        try files.atomicWrite(previous, to: files.backupURL)
        try failureInjector?(.afterBackup)
        try failureInjector?(.beforeManifestCommit)
        try Task.checkCancellation()
        try files.atomicWrite(data, to: files.currentURL)
        // Nothing after the atomic commit may turn a successful save into a reported failure.
        manifest = next
        return snapshot(for: next)
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
            let initial = try files.encode(LibraryManifest(notebooks: [sample]))
            try initial.write(to: staging.appendingPathComponent("manifest.json"))
            try initial.write(to: staging.appendingPathComponent("manifest.backup.json"))
            try failureInjector?(.beforeInitialInstall)
            try Task.checkCancellation()
            try files.moveAtomically(from: staging, to: rootURL)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private func cleanUnusedPDFs(current: LibraryManifest, backup: LibraryManifest?) {
        let referenced = Set((current.notebooks + (backup?.notebooks ?? [])).compactMap(\.revisionID).map { "\($0.uuidString).pdf" })
        guard let files = try? fileManager.contentsOfDirectory(at: files.pdfFolder, includingPropertiesForKeys: nil) else { return }
        for file in files where !referenced.contains(file.lastPathComponent) {
            if file.pathExtension == "pdf" || file.pathExtension == "pending" {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}

enum TemporaryPDFCleanup {
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
