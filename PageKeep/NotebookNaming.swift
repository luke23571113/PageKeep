import Foundation

enum NotebookNaming {
    static func resolvedName(
        _ proposedName: String,
        in notebooks: [Notebook],
        excluding notebookID: UUID? = nil
    ) throws -> String {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryError.emptyName }
        let names = notebooks.filter { $0.id != notebookID }.map {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func isAvailable(_ name: String) -> Bool {
            !names.contains { $0.compare(name, options: .caseInsensitive) == .orderedSame }
        }
        guard !isAvailable(trimmed) else { return trimmed }

        var base = trimmed
        if let suffix = trimmed.range(of: #" \([0-9]+\)$"#, options: .regularExpression) {
            let withoutSuffix = String(trimmed[..<suffix.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !withoutSuffix.isEmpty { base = withoutSuffix }
        }
        var number = 1
        while !isAvailable("\(base) (\(number))") { number += 1 }
        return "\(base) (\(number))"
    }
}
