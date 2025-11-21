import CoreGraphics
import CoreText
import Foundation
import XCTest

@testable import pdf

final class PDFTests: XCTestCase {
  func testPageSelectorRangeAndSingles() throws {
    let selector = try PageSelector(rawValue: "1,3-4,2", pageCount: 5)
    XCTAssertEqual(selector.pageNumbers, [1, 2, 3, 4])
  }

  func testPageSelectorRejectsOutOfBounds() {
    XCTAssertThrowsError(try PageSelector(rawValue: "10-12", pageCount: 5))
  }

  func testPatternMatcherSubstringCaseInsensitive() throws {
    let matcher = try PatternMatcher(keywords: ["Snapshot"], regex: false, caseSensitive: false)
    XCTAssertTrue(matcher.matches(line: "snapshot created"))
    XCTAssertFalse(matcher.matches(line: "no match here"))
  }

  func testPatternMatcherRegex() throws {
    let matcher = try PatternMatcher(keywords: ["snap.*"], regex: true, caseSensitive: false)
    XCTAssertTrue(matcher.matches(line: "snapshots are stored"))
  }

  func testSearchTermLoaderCombinesFileAndCLI() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try "alpha\nbeta".write(to: tmp, atomically: true, encoding: .utf8)

    let terms = try SearchTermLoader.load(cliTerms: ["gamma,delta"], termsFile: tmp.path)
    XCTAssertEqual(Set(terms), Set(["alpha", "beta", "gamma", "delta"]))
  }

  func testSearchZeroContextDoesNotTrap() throws {
    let pdfURL = try makeTestPDF(pages: [["keybag"]])

    let search = try PDF.Search.parse([
      pdfURL.path,
      "--term", "keybag",
      "--no-defaults",
      "--format", "json",
      "--no-headers",
    ])

    XCTAssertNoThrow(try search.run())
  }

  func testPDFExtractionReadsText() throws {
    let pdfURL = try makeTestPDF(pages: [
      ["snapshot rollback", "hello world"],
      ["journal entry two"],
    ])

    let doc = try PDFLoader.open(path: pdfURL.path)
    XCTAssertEqual(doc.pageCount, 2)

    let pageOne = doc.page(at: 0)?.string ?? ""
    let pageTwo = doc.page(at: 1)?.string ?? ""

    XCTAssertTrue(pageOne.contains("snapshot rollback"))
    XCTAssertTrue(pageTwo.contains("journal entry two"))
  }
}

// MARK: - Test helpers

private func makeTestPDF(pages: [[String]]) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
    .appendingPathExtension("pdf")

  var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)  // US Letter-ish
  guard let consumer = CGDataConsumer(url: url as CFURL) else {
    throw XCTSkip("Could not create data consumer")
  }
  guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
    throw XCTSkip("Could not create PDF context")
  }

  let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)

  for pageLines in pages {
    context.beginPDFPage(nil)
    var y: CGFloat = mediaBox.height - 72  // top margin
    for line in pageLines {
      let attr: [NSAttributedString.Key: Any] = [
        kCTFontAttributeName as NSAttributedString.Key: font
      ]
      let attributed = NSAttributedString(string: line, attributes: attr)
      let ctLine = CTLineCreateWithAttributedString(attributed)
      context.textPosition = CGPoint(x: 54, y: y)
      CTLineDraw(ctLine, context)
      y -= 18
    }
    context.endPDFPage()
  }
  context.closePDF()

  return url
}
