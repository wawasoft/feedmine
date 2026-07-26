import XCTest
@testable import feedmine

final class TaxonomyNodeTests: XCTestCase {

    func testRootNodeID() {
        let root = TaxonomyNode.root(feedCount: 0, childrenCount: 0)
        XCTAssertEqual(root.id, "__root__")
    }

    func testIsAncestorDirect() {
        let parent = TaxonomyNode(id: "countries/brazil", name: "Brazil",
                                  parentId: "__root__", childrenCount: 1,
                                  feedCount: 100, language: nil, level: 1, kind: .country)
        let child = TaxonomyNode(id: "countries/brazil/news", name: "News",
                                 parentId: "countries/brazil", childrenCount: 0,
                                 feedCount: 10, language: nil, level: 2, kind: .subcategory)
        XCTAssertTrue(parent.isAncestor(of: child.id))
    }

    func testIsAncestorFalse() {
        let a = TaxonomyNode(id: "countries/brazil", name: "Brazil",
                             parentId: "__root__", childrenCount: 1,
                             feedCount: 100, language: nil, level: 1, kind: .country)
        let b = TaxonomyNode(id: "countries/argentina", name: "Argentina",
                             parentId: "__root__", childrenCount: 0,
                             feedCount: 50, language: nil, level: 1, kind: .country)
        XCTAssertFalse(a.isAncestor(of: b.id))
    }

    func testRootIsAncestorOfNone() {
        let root = TaxonomyNode.root(feedCount: 0, childrenCount: 0)
        let child = TaxonomyNode(id: "countries/brazil", name: "Brazil",
                                 parentId: "__root__", childrenCount: 1,
                                 feedCount: 100, language: nil, level: 1, kind: .country)
        // Root ID is __root__ which no child starts with
        XCTAssertFalse(root.isAncestor(of: child.id))
    }
}
