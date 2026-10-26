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
        case 2:
            guard let current = try? JSONDecoder().decode(LibraryManifest.self, from: data),
                  current.initialized else { throw LibraryError.damagedManifest }
            decoded = current
        case 3...:
            throw LibraryError.newerSchema
        default:
            throw LibraryError.damagedManifest
        }
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
