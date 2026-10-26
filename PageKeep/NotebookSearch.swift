import Foundation

enum NotebookSearch {
    static func results(in notebooks: [Notebook], query: String) -> [Notebook] {
        let query = normalized(query)
        guard !query.isEmpty else { return notebooks }
        let tokens = query.split(separator: " ").map(String.init)
        return notebooks.enumerated().compactMap { index, notebook -> (Notebook, Int, Int)? in
            let title = normalized(notebook.name)
            let words = title.split { !$0.isLetter && !$0.isNumber }.map(String.init)
            let rank: Int
            if title == query {
                rank = 0
            } else if title.hasPrefix(query) {
                rank = 1
            } else if tokens.allSatisfy({ token in words.contains { $0.hasPrefix(token) } }) {
                rank = 2
            } else if tokens.allSatisfy({ title.contains($0) }) {
                rank = 3
            } else {
                return nil
            }
            return (notebook, rank, index)
        }
        .sorted { left, right in
            left.1 == right.1 ? left.2 < right.2 : left.1 < right.1
        }
        .map { $0.0 }
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
