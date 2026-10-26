import XCTest
@testable import PageKeep

final class NotebookNamingTests: XCTestCase {
    func testTrimsAndRejectsBlankNames() throws {
        XCTAssertEqual(try NotebookNaming.resolvedName("  Math\n", in: []), "Math")
        XCTAssertThrowsError(try NotebookNaming.resolvedName(" \n ", in: []))
    }

    func testUsesFirstAvailableSuffixAcrossArchivedAndActiveNames() throws {
        let notebooks = [notebook("Math"), notebook("math (1)", archived: true), notebook("Math (3)")]
        XCTAssertEqual(try NotebookNaming.resolvedName(" MATH ", in: notebooks), "MATH (2)")
    }

    func testExistingSuffixIsReplacedOnlyWhenThereIsAConflict() throws {
        let notebooks = [notebook("Math (4)"), notebook("Math (1)"), notebook("Math")]
        XCTAssertEqual(try NotebookNaming.resolvedName("Math (4)", in: notebooks), "Math (2)")
        XCTAssertEqual(try NotebookNaming.resolvedName("Math (8)", in: notebooks), "Math (8)")
        XCTAssertEqual(try NotebookNaming.resolvedName("Chapter (notes)", in: [notebook("Chapter (notes)")]), "Chapter (notes) (1)")
    }

    func testEditingExcludesOnlyItsOwnIDAndKeepsOtherLegacyDuplicates() throws {
        let own = notebook("Math")
        XCTAssertEqual(try NotebookNaming.resolvedName(" math ", in: [own], excluding: own.id), "math")
        XCTAssertEqual(try NotebookNaming.resolvedName("Math", in: [own, notebook("Math")], excluding: own.id), "Math (1)")
    }

    private func notebook(_ name: String, archived: Bool = false) -> Notebook {
        Notebook(
            id: UUID(), name: name, createdAt: .distantPast, modifiedAt: .distantPast,
            revisionID: nil, pages: [], isArchived: archived
        )
    }
}
