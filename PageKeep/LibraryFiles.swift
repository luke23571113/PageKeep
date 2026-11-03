import Foundation
import Darwin

struct LibraryFiles {
    let rootURL: URL
    private let fileManager = FileManager.default

    var currentURL: URL { rootURL.appendingPathComponent("manifest.json") }
    var backupURL: URL { rootURL.appendingPathComponent("manifest.backup.json") }
    var pdfFolder: URL { rootURL.appendingPathComponent("PDFs", isDirectory: true) }

    func readManifest(at url: URL) throws -> LibraryManifest {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw LibraryError.damagedManifest }
        // Read the version separately so a newer format is never mistaken for corruption.
        struct Version: Decodable { let schemaVersion: Int }
        guard let version = try? JSONDecoder().decode(Version.self, from: data) else {
            throw LibraryError.damagedManifest
        }
        let decoded: LibraryManifest
        switch version.schemaVersion {
        case 1:
            guard let legacy = try? JSONDecoder().decode(LegacyLibraryManifest.self, from: data),
                  legacy.initialized else { throw LibraryError.damagedManifest }
            decoded = legacy.migrated()
        case 2, 3, 4:
            guard let current = try? JSONDecoder().decode(LibraryManifest.self, from: data),
                  current.initialized else { throw LibraryError.damagedManifest }
            decoded = current
        case 5...:
            throw LibraryError.newerSchema
        default:
            throw LibraryError.damagedManifest
        }
        if version.schemaVersion >= 3 {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["sync"] != nil,
                  let notebooks = object["notebooks"] as? [[String: Any]],
                  notebooks.allSatisfy({ $0["contentVersionID"] != nil && $0["contentHistory"] != nil && $0["fieldClocks"] != nil }) else {
                throw LibraryError.damagedManifest
            }
        }
        if version.schemaVersion == 4 {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["folders"] != nil, object["itemOrder"] != nil else { throw LibraryError.damagedManifest }
        }
        try validate(decoded)
        return decoded
    }

    func validate(_ manifest: LibraryManifest) throws {
        guard manifest.schemaVersion == 4, manifest.initialized,
              Set(manifest.notebooks.map(\.id)).count == manifest.notebooks.count,
              Set(manifest.sync.tombstones.map(\.id)).count == manifest.sync.tombstones.count,
              Set(manifest.sync.outbox.map(\.id)).count == manifest.sync.outbox.count,
              Set(manifest.sync.orderMoves.map(\.id)).count == manifest.sync.orderMoves.count else {
            throw LibraryError.damagedManifest
        }
        let itemIDs = manifest.notebooks.map(\.id) + manifest.folders.map(\.id)
        guard Set(itemIDs).count == itemIDs.count,
              manifest.itemOrder.count == itemIDs.count,
              Set(manifest.itemOrder) == Set(itemIDs),
              Set(manifest.sync.folderTombstones.map(\.id)).count == manifest.sync.folderTombstones.count,
              Set(manifest.folders.map(\.id)).isDisjoint(with: manifest.sync.folderTombstones.map(\.id)) else {
            throw LibraryError.damagedManifest
        }
        for folder in manifest.folders + manifest.sync.outbox.compactMap(\.folder) {
            guard !folder.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.damagedManifest }
        }
        try validateCompatibleVersions([manifest])
        let notebooks = manifest.notebooks + manifest.sync.tombstones.map(\.notebook) + manifest.sync.outbox.compactMap(\.notebook)
        var versions: [UUID: NotebookContentVersion] = [:]
        for notebook in notebooks {
            guard !notebook.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  Set(notebook.pages.map(\.id)).count == notebook.pages.count,
                  notebook.pages.isEmpty == (notebook.revisionID == nil),
                  !notebook.contentAncestors.contains(notebook.contentVersionID),
                  let current = notebook.contentHistory.first(where: { $0.id == notebook.contentVersionID }),
                  current.pages == notebook.pages, current.revisionID == notebook.revisionID else {
                throw LibraryError.damagedManifest
            }
            var records: [UUID: NotebookContentVersion] = [:]
            for version in notebook.contentHistory {
                guard records[version.id] == nil,
                      versions[version.id] == nil || versions[version.id] == version,
                      !version.parentIDs.contains(version.id), version.parentIDs.count <= 1,
                      version.pages.isEmpty == (version.revisionID == nil),
                      Set(version.pages.map(\.id)).count == version.pages.count else {
                    throw LibraryError.damagedManifest
                }
                records[version.id] = version
                versions[version.id] = version
            }
            var resolved = Set(records.values.filter { $0.parentIDs.isEmpty }.map(\.id))
            while true {
                let ready = records.values.filter { $0.parentIDs.isSubset(of: resolved) }.map(\.id)
                let expanded = resolved.union(ready)
                if expanded == resolved { break }
                resolved = expanded
            }
            guard resolved.count == records.count else { throw LibraryError.damagedManifest }
            var ancestors = Set<UUID>()
            var pending = Array(current.parentIDs)
            while let id = pending.popLast() {
                guard id != current.id, let record = records[id] else { throw LibraryError.damagedManifest }
                if ancestors.insert(id).inserted { pending.append(contentsOf: record.parentIDs) }
            }
            guard ancestors == notebook.contentAncestors else { throw LibraryError.damagedManifest }
        }
        for entry in manifest.sync.outbox {
            let count = (entry.notebook == nil ? 0 : 1) + (entry.tombstone == nil ? 0 : 1) + (entry.move == nil ? 0 : 1) + (entry.folder == nil ? 0 : 1) + (entry.folderTombstone == nil ? 0 : 1)
            guard count == 1 else { throw LibraryError.damagedManifest }
        }
    }

    func validateCompatibleVersions(_ manifests: [LibraryManifest]) throws {
        var versions: [UUID: NotebookContentVersion] = [:]
        var revisions: [UUID: [NotebookPage]] = [:]
        for manifest in manifests {
            let notebooks = manifest.notebooks + manifest.sync.tombstones.map(\.notebook) + manifest.sync.outbox.compactMap(\.notebook)
            for version in notebooks.flatMap(\.contentHistory) {
                guard versions[version.id] == nil || versions[version.id] == version else { throw LibraryError.damagedManifest }
                versions[version.id] = version
                if let revision = version.revisionID {
                    guard revisions[revision] == nil || revisions[revision] == version.pages else { throw LibraryError.damagedManifest }
                    revisions[revision] = version.pages
                }
            }
        }
    }

    func shareFileName(_ name: String) -> String {
        let sanitized = name.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters))
            .joined(separator: "-")
        var result = ""
        for character in sanitized {
            guard result.utf8.count + String(character).utf8.count <= 180 else { break }
            result.append(character)
        }
        return result.isEmpty ? "Notebook" : result
    }

    func coordinatedCopy(from source: URL, to destination: URL) throws {
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

    func encode(_ manifest: LibraryManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(manifest)
    }

    func atomicWrite(_ data: Data, to destination: URL) throws {
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

    func moveAtomically(from source: URL, to destination: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                Darwin.rename(sourcePath!, destinationPath!)
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
