import XCTest
import CoreGraphics
@testable import redact_names

final class GeometryTests: XCTestCase {
    // A box hugging the TOP of a 1000x2000 page, in Vision terms: y near 1, normalized.
    func testVisionTopEdgeBecomesImageTop() {
        let vision = CGRect(x: 0.1, y: 0.9, width: 0.5, height: 0.1)
        let img = Geometry.visionToImage(vision, imageSize: CGSize(width: 1000, height: 2000))
        XCTAssertEqual(img.minX, 100, accuracy: 0.001)
        XCTAssertEqual(img.minY, 0, accuracy: 0.001)       // top of the page
        XCTAssertEqual(img.width, 500, accuracy: 0.001)
        XCTAssertEqual(img.height, 200, accuracy: 0.001)
    }

    func testBottomOfPageStaysAtBottom() {
        let vision = CGRect(x: 0, y: 0, width: 1, height: 0.1)
        let img = Geometry.visionToImage(vision, imageSize: CGSize(width: 1000, height: 2000))
        XCTAssertEqual(img.maxY, 2000, accuracy: 0.001)
    }

    func testImageToContextFlipsBack() {
        let r = CGRect(x: 10, y: 0, width: 50, height: 100)       // touching the top
        let c = Geometry.imageToContext(r, imageHeight: 2000)
        XCTAssertEqual(c.minY, 1900, accuracy: 0.001)
        XCTAssertEqual(c.maxY, 2000, accuracy: 0.001)
    }

    func testRoundTrip() {
        let size = CGSize(width: 800, height: 1000)
        let vision = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.05)
        let img = Geometry.visionToImage(vision, imageSize: size)
        let ctx = Geometry.imageToContext(img, imageHeight: size.height)
        // The CGContext rect must equal the Vision rect scaled to pixels.
        XCTAssertEqual(ctx.minY, 0.3 * 1000, accuracy: 0.001)
        XCTAssertEqual(ctx.minX, 0.2 * 800, accuracy: 0.001)
    }

    func testInflateStaysOnPage() {
        let r = Geometry.inflate(CGRect(x: 2, y: 2, width: 10, height: 10), by: 8,
                                 within: CGSize(width: 100, height: 100))
        XCTAssertEqual(r.minX, 0); XCTAssertEqual(r.minY, 0)
    }
}

final class RosterTests: XCTestCase {
    func testLevenshtein() {
        XCTAssertEqual(RosterMatcher.levenshtein("kitten", "sitting"), 3)
        XCTAssertEqual(RosterMatcher.levenshtein("", "abc"), 3)
        XCTAssertEqual(RosterMatcher.levenshtein("same", "same"), 0)
    }

    func testFuzzyMatch() {
        let m = RosterMatcher(names: ["Jordan Whitfield"], threshold: 0.85)
        XCTAssertTrue(m.matches("by Jordan Whitfield"))
        XCTAssertTrue(m.matches("Whitfeld"))             // one dropped letter: 1 edit of 9 = 0.89
        XCTAssertFalse(m.matches("Whitfeild"))           // a swap costs 2 edits: 0.78, below 0.85
        XCTAssertFalse(m.matches("Solve for x"))
    }

    func testShortWordsIgnored() {
        let m = RosterMatcher(names: ["Al Li Wong"], threshold: 0.85)
        XCTAssertEqual(m.words, ["wong"])                // "Al" and "Li" are under 3 letters
    }

    func testAccentsAndCase() {
        let m = RosterMatcher(names: ["José Núñez"], threshold: 0.85)
        XCTAssertTrue(m.matches("JOSE NUNEZ"))
    }
}

final class NameDetectorTests: XCTestCase {
    let standard = NameDetector(mode: .standard)
    let aggressive = NameDetector(mode: .aggressive)

    private func flagged(_ text: String, _ d: NameDetector) -> [String] {
        d.hits(in: text).map { String(text[$0.range]) }
    }

    func testFindsListedNames() {
        XCTAssertTrue(flagged("Jordan", standard).contains("Jordan"))
        XCTAssertTrue(flagged("said Atticus quietly", standard).contains("Atticus"))
    }

    func testOrdinaryWordsSurvive() {
        for d in [standard, aggressive] {
            XCTAssertEqual(flagged("We should grace the table with a good story.", d), [])
            XCTAssertEqual(flagged("before the mark is reached", d), [])
            XCTAssertEqual(flagged("The weather will grow cold", d), [])   // "the" is not a name
        }
    }

    func testAggressiveCatchesUnknownCapitalizedWord() {
        XCTAssertEqual(flagged("Zorblax", standard), [])
        XCTAssertEqual(flagged("Zorblax", aggressive), ["Zorblax"])
    }

    func testCapitalizedRunOnlyInAggressive() {
        XCTAssertEqual(flagged("Zorblax Quindle", standard), [])
        XCTAssertEqual(Set(flagged("Zorblax Quindle", aggressive)).count, 2)
    }

    func testRunDoesNotJumpOverNumbers() {
        XCTAssertEqual(flagged("Algebra 1 - Quiz 3", aggressive), [])
    }
}
