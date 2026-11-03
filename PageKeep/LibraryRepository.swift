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
            revisionID: nil, pages: [], symbolName: details.symbolName, colorID: details.colorID,
            folderID: validFolderID(details.folderID, in: next)
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
        next.itemOrder.insert(id, at: 0)
        return try commit(next)
    }

    func edit(
        _ id: UUID, details: NotebookDetails, appending additions: [PreparedPDF],
        pageLayout: [DraftPage]? = nil, expectedExistingPageIDs: [UUID]? = nil,
        baseNotebook: Notebook? = nil, basePDFURL: URL? = nil, draftVersionID: UUID? = nil
    ) throws -> LibrarySnapshot {
        var next = try loadedManifest()
        if let baseNotebook {
            let saved = next.notebooks.first { $0.id == id }
            let contentEdited = pageLayout != nil || !additions.isEmpty
            if saved == nil || (contentEdited && saved?.contentVersionID != baseNotebook.contentVersionID) {
                return try saveDivergedDraft(
                    baseNotebook, details: details, additions: additions, pageLayout: pageLayout,
                    sourceURL: basePDFURL, versionID: draftVersionID ?? UUID(), current: next
                )
            }
        }
        let index = try notebookIndex(id, in: next)
        let original = next.notebooks[index]
        if let baseNotebook {
            guard baseNotebook.id == id else { throw LibraryError.invalidChange }
            if pageLayout != nil || !additions.isEmpty {
                guard original.contentVersionID == baseNotebook.contentVersionID else { throw LibraryError.invalidChange }
            }
            // A draft only owns fields that the user actually changed.
            next.notebooks[index].name = details.name == baseNotebook.name ? original.name :
                try NotebookNaming.resolvedName(details.name, in: next.notebooks, excluding: id)
            if details.symbolName != baseNotebook.symbolName { next.notebooks[index].symbolName = details.symbolName }
            if details.colorID != baseNotebook.colorID { next.notebooks[index].colorID = details.colorID }
            if details.folderID != baseNotebook.folderID {
                next.notebooks[index].folderID = validFolderID(details.folderID, in: next)
            }
        } else {
            next.notebooks[index].name = try NotebookNaming.resolvedName(details.name, in: next.notebooks, excluding: id)
            next.notebooks[index].symbolName = details.symbolName
            next.notebooks[index].colorID = details.colorID
            if details.folderID != original.folderID {
                next.notebooks[index].folderID = validFolderID(details.folderID, in: next)
            }
        }
        if next.notebooks[index].folderID != original.folderID {
            appendItem(id, in: &next)
        }
        if pageLayout != nil, let expectedExistingPageIDs, expectedExistingPageIDs != original.pages.map(\.id) {
            throw LibraryError.invalidChange
        }
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

    private func saveDivergedDraft(
        _ base: Notebook, details: NotebookDetails, additions: [PreparedPDF], pageLayout: [DraftPage]?,
        sourceURL: URL?, versionID: UUID, current: LibraryManifest
    ) throws -> LibrarySnapshot {
        guard details != base.details || pageLayout != nil || !additions.isEmpty else {
            throw LibraryError.notebookNotFound
        }
        var next = current
        var branch = base
        let clock = next.sync.nextClock()
        if details.name != base.name {
            guard !details.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.emptyName }
            branch.name = details.name
            branch.requestedName = details.name
            branch.fieldClocks.name = clock
        }
        if details.symbolName != base.symbolName { branch.symbolName = details.symbolName; branch.fieldClocks.symbol = clock }
        if details.colorID != base.colorID { branch.colorID = details.colorID; branch.fieldClocks.color = clock }
        if details.folderID != base.folderID {
            branch.folderID = validFolderID(details.folderID, in: next)
            branch.fieldClocks.folder = clock
        }
        if pageLayout != nil || !additions.isEmpty {
            let source: PDFDocument
            if base.pages.isEmpty { source = PDFDocument() }
            else if let sourceURL {
                source = try PDFService.validate(at: sourceURL)
                guard source.pageCount == base.pageCount else { throw LibraryError.pageCountMismatch }
            } else { source = try document(for: base) }
            let documents = try additions.map { try preparedDocument($0) }
            let output: PDFDocument
            if let pageLayout {
                output = try PDFPageComposition.arrangedDocument(
                    pageLayout, existingNotebook: base, existingDocument: source,
                    additions: additions, documents: documents
                )
                branch.pages = pageLayout.map { NotebookPage(id: $0.id) }
            } else {
                output = source
                try PDFPageComposition.append(documents, to: output, notebook: &branch)
            }
            try updatePDF(output, notebook: &branch)
            branch.contentVersionID = versionID
            branch.contentAncestors.insert(base.contentVersionID)
            branch.contentHistory.append(NotebookContentVersion(
                id: versionID, parentIDs: [base.contentVersionID], revisionID: branch.revisionID, pages: branch.pages
            ))
        }
        if !branch.pages.isEmpty, let destination = pdfURL(for: branch),
           !fileManager.fileExists(atPath: destination.path) {
            guard let sourceURL else { throw LibraryError.missingPDF }
            let source = try PDFService.validate(at: sourceURL)
            guard source.pageCount == branch.pageCount else { throw LibraryError.pageCountMismatch }
            let temporary = destination.deletingPathExtension().appendingPathExtension("pending")
            do {
                try fileManager.copyItem(at: sourceURL, to: temporary)
                try files.moveAtomically(from: temporary, to: destination)
            } catch {
                try? fileManager.removeItem(at: temporary)
                throw error
            }
        }
        branch.modifiedAt = Date()
        let incoming = LibraryManifest(notebooks: [branch], folders: next.folders, sync: next.sync)
        next = LibraryReconciliation.merge(next, with: incoming)
        let saved = next.notebooks.first { $0.contentVersionID == branch.contentVersionID && $0.id != base.id }
            ?? next.notebooks.first { $0.contentVersionID == branch.contentVersionID }
        guard let saved else { throw LibraryError.invalidChange }
        for notebook in next.notebooks where current.notebooks.first(where: { $0.id == notebook.id }) != notebook {
            next.sync.outbox.append(SyncOutboxEntry(id: UUID(), notebook: notebook, tombstone: nil, move: nil, clock: SyncClock(counter: next.sync.logicalClock, deviceID: next.sync.deviceID)))
        }
        var snapshot = try commit(next, recordingLocalChanges: false)
        snapshot.savedNotebookID = saved.id
        return snapshot
    }

    func createFolder(id: UUID = UUID(), name: String) throws -> LibrarySnapshot {
        var next = try loadedManifest()
        guard !next.itemOrder.contains(id), !next.sync.folderTombstones.contains(where: { $0.id == id }) else { throw LibraryError.invalidChange }
        let resolved = try NotebookNaming.resolvedFolderName(name, in: next.folders)
        next.folders.append(NotebookFolder(id: id, name: resolved))
        next.itemOrder.append(id)
        return try commit(next)
    }

    func renameFolder(_ id: UUID, name: String) throws -> LibrarySnapshot {
        var next = try loadedManifest()
        guard let index = next.folders.firstIndex(where: { $0.id == id }) else { throw LibraryError.folderNotFound }
        next.folders[index].name = try NotebookNaming.resolvedFolderName(name, in: next.folders, excluding: id)
        guard next.folders[index] != manifest?.folders.first(where: { $0.id == id }) else { return snapshot(for: next) }
        return try commit(next)
    }

    func deleteFolder(_ id: UUID) throws -> LibrarySnapshot {
        var next = try loadedManifest()
        guard next.folders.contains(where: { $0.id == id }) else { throw LibraryError.folderNotFound }
        let children = next.itemIDs(in: id, includingArchived: true)
        next.folders.removeAll { $0.id == id }
        for index in next.notebooks.indices where next.notebooks[index].folderID == id {
            next.notebooks[index].folderID = nil
            next.notebooks[index].modifiedAt = Date()
        }
        next.itemOrder.removeAll { $0 == id || children.contains($0) }
        next.itemOrder.append(contentsOf: children)
        return try commit(next)
    }

    func moveNotebook(_ id: UUID, toFolderID folderID: UUID?) throws -> LibrarySnapshot {
        var next = try loadedManifest()
        if let folderID, !next.folders.contains(where: { $0.id == folderID }) { throw LibraryError.folderNotFound }
        let index = try notebookIndex(id, in: next)
        guard next.notebooks[index].folderID != folderID else { return snapshot(for: next) }
        next.notebooks[index].folderID = folderID
        next.notebooks[index].modifiedAt = Date()
        appendItem(id, in: &next)
        return try commit(next)
    }

    func reorderItems(inFolderID folderID: UUID?, orderedIDs: [UUID]) throws -> LibrarySnapshot {
        var next = try loadedManifest()
        if let folderID, !next.folders.contains(where: { $0.id == folderID }) { throw LibraryError.folderNotFound }
        let activeIDs = next.itemIDs(in: folderID)
        guard orderedIDs.count == activeIDs.count, Set(orderedIDs).count == orderedIDs.count,
              Set(orderedIDs) == Set(activeIDs) else { throw LibraryError.invalidChange }
        guard orderedIDs != activeIDs else { return snapshot(for: next) }
        replaceOrder(activeIDs, with: orderedIDs, in: &next)
        return try commit(next)
    }

    func reorderNotebooks(orderedActiveIDs: [UUID]) throws -> LibrarySnapshot {
        var next = try loadedManifest()
        let activeIDs = next.notebooks.filter { !$0.isArchived }.map(\.id)
        guard orderedActiveIDs.count == activeIDs.count, Set(orderedActiveIDs).count == orderedActiveIDs.count,
              Set(orderedActiveIDs) == Set(activeIDs) else { throw LibraryError.invalidChange }
        guard orderedActiveIDs != activeIDs else { return snapshot(for: next) }
        replaceOrder(activeIDs, with: orderedActiveIDs, in: &next)
        return try commit(next)
    }

    private func validFolderID(_ id: UUID?, in manifest: LibraryManifest) -> UUID? {
        id.flatMap { id in manifest.folders.contains(where: { $0.id == id }) ? id : nil }
    }

    private func appendItem(_ id: UUID, in manifest: inout LibraryManifest) {
        manifest.itemOrder.removeAll { $0 == id }
        manifest.itemOrder.append(id)
    }

    private func replaceOrder(_ ids: [UUID], with orderedIDs: [UUID], in manifest: inout LibraryManifest) {
        let slots = manifest.itemOrder.indices.filter { ids.contains(manifest.itemOrder[$0]) }
        for (slot, id) in zip(slots, orderedIDs) { manifest.itemOrder[slot] = id }
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
        next.itemOrder.removeAll { $0 == id }
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

    func prepareForSync() throws -> LibrarySnapshot {
        var next = try loadedManifest()
        guard next.sync.needsBootstrap else { return snapshot(for: next) }
        for notebook in next.notebooks where !next.sync.outbox.contains(where: { $0.notebook == notebook }) {
            let clock = next.sync.nextClock()
            next.sync.outbox.append(SyncOutboxEntry(id: UUID(), notebook: notebook, tombstone: nil, move: nil, clock: clock))
        }
        for folder in next.folders where !next.sync.outbox.contains(where: { $0.folder == folder }) {
            let clock = next.sync.nextClock()
            next.sync.outbox.append(SyncOutboxEntry(id: UUID(), notebook: nil, tombstone: nil, move: nil, clock: clock, folder: folder))
        }
        next.sync.needsBootstrap = false
        return try commit(next, recordingLocalChanges: false)
    }

    func resetSyncForNewAccount() throws -> LibrarySnapshot {
        var next = try loadedManifest()
        next.sync = LibrarySyncState()
        next.sync.baseOrder = next.itemOrder
        for index in next.folders.indices { next.folders[index].nameClock = SyncClock() }
        for index in next.notebooks.indices {
            next.notebooks[index].contentAncestors = []
            next.notebooks[index].contentHistory = []
            next.notebooks[index].conflictOriginID = nil
            next.notebooks[index].recoverySourceID = nil
            next.notebooks[index].fieldClocks = NotebookFieldClocks()
        }
        recordLocalChanges(from: LibraryManifest(notebooks: [], sync: next.sync), in: &next)
        return try commit(next, recordingLocalChanges: false)
    }

    func syncSnapshot() throws -> LibraryManifest {
        try loadedManifest()
    }

    func acknowledgeSyncEntries(_ ids: Set<UUID>) throws -> LibrarySnapshot {
        var next = try loadedManifest()
        next.sync.outbox.removeAll { ids.contains($0.id) }
        return try commit(next, recordingLocalChanges: false)
    }

    func dismissSyncNotice(_ id: UUID) throws -> LibrarySnapshot {
        var next = try loadedManifest()
        next.sync.notices.removeAll { $0.id == id }
        next.sync.dismissedNoticeIDs.insert(id)
        return try commit(next, recordingLocalChanges: false)
    }

    func reconcile(with remote: LibraryManifest, downloadedPDFs: [UUID: URL]) throws -> LibrarySnapshot {
        let current = try loadedManifest()
        try files.validate(remote)
        try files.validateCompatibleVersions([current, remote])
        var next = LibraryReconciliation.merge(current, with: remote)
        for notebook in next.notebooks where !notebook.pages.isEmpty {
            guard let revision = notebook.revisionID, let destination = pdfURL(for: notebook) else {
                throw LibraryError.missingPDF
            }
            if !fileManager.fileExists(atPath: destination.path) {
                guard let source = downloadedPDFs[revision] else { throw LibraryError.missingPDF }
                let incoming = try PDFService.validate(at: source)
                guard incoming.pageCount == notebook.pageCount else { throw LibraryError.pageCountMismatch }
                let temporary = files.pdfFolder.appendingPathComponent("\(revision.uuidString).pending")
                do {
                    try fileManager.copyItem(at: source, to: temporary)
                    let copied = try PDFService.validate(at: temporary)
                    guard copied.pageCount == notebook.pageCount else { throw LibraryError.pageCountMismatch }
                    try files.moveAtomically(from: temporary, to: destination)
                    try failureInjector?(.afterCandidatePDF)
                } catch {
                    try? fileManager.removeItem(at: temporary)
                    throw error
                }
            }
            _ = try document(for: notebook)
        }
        // Recovered/conflict copies must also be uploaded; their IDs make retries repeatable.
        let currentIDs = Set(current.notebooks.map(\.id))
        let remoteIDs = Set(remote.notebooks.map(\.id))
        for notebook in next.notebooks {
            // The cloud inbox can derive a copy before it has its own uploaded record.
            let isPreservedCopy = notebook.conflictOriginID != nil || notebook.recoverySourceID != nil
            guard !currentIDs.contains(notebook.id), !remoteIDs.contains(notebook.id) || isPreservedCopy else { continue }
            next.sync.outbox.append(SyncOutboxEntry(id: UUID(), notebook: notebook, tombstone: nil, move: nil, clock: SyncClock(counter: next.sync.logicalClock, deviceID: next.sync.deviceID)))
        }
        return try commit(next, recordingLocalChanges: false)
    }

    private func recordLocalChanges(from previous: LibraryManifest, in next: inout LibraryManifest) {
        let old = Dictionary(uniqueKeysWithValues: previous.notebooks.map { ($0.id, $0) })
        let currentIDs = Set(next.notebooks.map(\.id))
        for index in next.notebooks.indices {
            let before = old[next.notebooks[index].id]
            guard before != next.notebooks[index] else { continue }
            let clock = next.sync.nextClock()
            if let before {
                if before.revisionID != next.notebooks[index].revisionID || before.pages != next.notebooks[index].pages {
                    next.notebooks[index].contentAncestors.insert(before.contentVersionID)
                    next.notebooks[index].contentVersionID = UUID()
                }
            } else {
                next.notebooks[index].contentVersionID = UUID()
            }
            if before?.contentVersionID != next.notebooks[index].contentVersionID {
                let version = NotebookContentVersion(
                    id: next.notebooks[index].contentVersionID,
                    parentIDs: before.map { [$0.contentVersionID] } ?? [],
                    revisionID: next.notebooks[index].revisionID, pages: next.notebooks[index].pages
                )
                if before == nil { next.notebooks[index].contentHistory = [] }
                next.notebooks[index].contentHistory.append(version)
            }
            if before?.name != next.notebooks[index].name {
                next.notebooks[index].fieldClocks.name = clock
                next.notebooks[index].requestedName = next.notebooks[index].name
            }
            if before?.symbolName != next.notebooks[index].symbolName { next.notebooks[index].fieldClocks.symbol = clock }
            if before?.colorID != next.notebooks[index].colorID { next.notebooks[index].fieldClocks.color = clock }
            if before?.isArchived != next.notebooks[index].isArchived { next.notebooks[index].fieldClocks.archived = clock }
            if before?.folderID != next.notebooks[index].folderID { next.notebooks[index].fieldClocks.folder = clock }
            next.sync.outbox.append(SyncOutboxEntry(id: UUID(), notebook: next.notebooks[index], tombstone: nil, move: nil, clock: clock))
        }
        for notebook in previous.notebooks where !currentIDs.contains(notebook.id) {
            let tombstone = NotebookTombstone(notebook: notebook, clock: next.sync.nextClock())
            next.sync.tombstones.removeAll { $0.id == notebook.id }
            next.sync.tombstones.append(tombstone)
            next.sync.outbox.append(SyncOutboxEntry(id: UUID(), notebook: nil, tombstone: tombstone, move: nil, clock: tombstone.clock))
        }
        let oldFolders = Dictionary(uniqueKeysWithValues: previous.folders.map { ($0.id, $0) })
        for index in next.folders.indices {
            let folder = next.folders[index]
            guard oldFolders[folder.id] != folder else { continue }
            let clock = next.sync.nextClock()
            next.folders[index].nameClock = clock
            next.folders[index].requestedName = folder.name
            next.sync.outbox.append(SyncOutboxEntry(id: UUID(), notebook: nil, tombstone: nil, move: nil,
                                                  clock: clock, folder: next.folders[index]))
        }
        for folder in previous.folders where !next.folders.contains(where: { $0.id == folder.id }) {
            let tombstone = FolderTombstone(id: folder.id, clock: next.sync.nextClock())
            next.sync.folderTombstones.removeAll { $0.id == folder.id }
            next.sync.folderTombstones.append(tombstone)
            next.sync.outbox.append(SyncOutboxEntry(id: UUID(), notebook: nil, tombstone: nil, move: nil,
                                                  clock: tombstone.clock, folderTombstone: tombstone))
        }
        let groups: [UUID?] = [nil] + Set(previous.folders.map(\.id) + next.folders.map(\.id)).sorted { $0.uuidString < $1.uuidString }.map { Optional($0) }
        for folderID in groups {
            let ordered = next.itemIDs(in: folderID, includingArchived: true)
            guard previous.itemIDs(in: folderID, includingArchived: true) != ordered else { continue }
            var beforeID: UUID?
            for id in ordered.reversed() {
                let move = NotebookOrderMove(
                    id: UUID(), notebookID: id, beforeID: beforeID, eligibleIDs: Set(ordered),
                    clock: next.sync.nextClock(), includesArchived: true, scoped: true, folderID: folderID
                )
                next.sync.orderMoves.append(move)
                next.sync.outbox.append(SyncOutboxEntry(id: UUID(), notebook: nil, tombstone: nil, move: move, clock: move.clock))
                beforeID = id
            }
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

    private func commit(_ proposed: LibraryManifest, recordingLocalChanges: Bool = true) throws -> LibrarySnapshot {
        var next = proposed
        let byID = Dictionary(uniqueKeysWithValues: next.notebooks.map { ($0.id, $0) })
        next.notebooks = next.itemOrder.compactMap { byID[$0] }
        if recordingLocalChanges {
            recordLocalChanges(from: try loadedManifest(), in: &next)
        }
        try files.validate(next)
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
            var initialManifest = LibraryManifest(notebooks: [sample])
            recordLocalChanges(from: LibraryManifest(notebooks: [], sync: initialManifest.sync), in: &initialManifest)
            let initial = try files.encode(initialManifest)
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
        let queued = (current.sync.outbox + (backup?.sync.outbox ?? [])).compactMap(\.notebook)
        let referenced = Set((current.notebooks + (backup?.notebooks ?? []) + queued).compactMap(\.revisionID).map { "\($0.uuidString).pdf" })
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
    case folderNotFound
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
        case .folderNotFound: "This folder could not be found."
        case .notebookNotFound: "This notebook could not be found."
        case .missingPDF: "The saved PDF is missing. You can delete this notebook or restore its file from a device backup."
        case .pageCountMismatch: "The saved PDF does not match this notebook's page list."
        case .emptyName: "Enter a notebook name."
        case .emptyNotebook: "Add pages before sharing this notebook."
        case .invalidChange: "The page selection has changed. Open the notebook again and retry."
        }
    }
}
