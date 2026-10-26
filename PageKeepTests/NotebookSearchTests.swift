import XCTest
@testable import PageKeep

final class NotebookSearchTests: XCTestCase {
    func testEmptySearchPreservesManualOrder() {
        let notebooks = makeNotebooks(["Zoology", "Math", "Art"])
        XCTAssertEqual(NotebookSearch.results(in: notebooks, query: " \n ").map(\.id), notebooks.map(\.id))
    }

    func testRanksExactPrefixWordPrefixAndSubstring() {
        let notebooks = makeNotebooks(["Aftermath", "Applied Math", "Mathematics", "Math"])
        XCTAssertEqual(NotebookSearch.results(in: notebooks, query: "math").map(\.name), ["Math", "Mathematics", "Applied Math", "Aftermath"])
    }

    func testAllTokensMustMatchAndWordPrefixesRankFirst() {
        let notebooks = makeNotebooks(["Nonlinear Algebra", "Linear Geometry", "Linear Algebra", "Algebra of Linear Maps"])
        XCTAssertEqual(NotebookSearch.results(in: notebooks, query: "lin alg").map(\.name), ["Linear Algebra", "Algebra of Linear Maps", "Nonlinear Algebra"])
    }

    func testIgnoresCaseAccentsAndExtraWhitespace() {
        let notebooks = makeNotebooks(["Café Notes", "Cafe Society", "Coffee"])
        XCTAssertEqual(NotebookSearch.results(in: notebooks, query: "  CAFÉ   notes\n").map(\.name), ["Café Notes"])
    }

    func testEqualRelevanceUsesManualOrder() {
        let notebooks = makeNotebooks(["Math Z", "Math A", "Math B"])
        XCTAssertEqual(NotebookSearch.results(in: notebooks, query: "math").map(\.id), notebooks.map(\.id))
    }

    func testNoMatchReturnsNoNotebooks() {
        XCTAssertTrue(NotebookSearch.results(in: makeNotebooks(["Physics", "Art"]), query: "math").isEmpty)
    }

    private func makeNotebooks(_ names: [String]) -> [Notebook] {
        names.map { name in
            Notebook(id: UUID(), name: name, createdAt: .distantPast, modifiedAt: .distantPast, revisionID: nil, pages: [])
        }
    }
}
