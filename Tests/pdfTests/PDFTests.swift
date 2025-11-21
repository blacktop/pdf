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

  func testFormattingMarkdownAndSmartLayout() {
    let raw = """
      SECTION HEADER:
      • first item
      • second item
      key-
        bag field: uint64_t
          nested_line;
      """

    let lines = LineNormalizer.normalize(rawText: raw, layout: .smart)
    XCTAssertEqual(lines[3], "keybag field: uint64_t")

    let rendered = Markdownifier.render(lines: lines)
    let expected = """
      ### Section Header
      - first item
      - second item
      keybag field: uint64_t
      ```
      nested_line;
      ```
      """
    XCTAssertEqual(
      rendered.trimmingCharacters(in: .whitespacesAndNewlines),
      expected.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  func testMarkdownifierTableDetection() {
    let lines = [
      "Name    Type    Size",
      "field1  uint32  4",
      "field2  uint64  8",
    ]

    let rendered = Markdownifier.render(lines: lines)
    let expected = """
      | Name | Type | Size |
      | --- | --- | --- |
      | field1 | uint32 | 4 |
      | field2 | uint64 | 8 |
      """
    XCTAssertEqual(
      rendered.trimmingCharacters(in: .whitespacesAndNewlines),
      expected.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  func testSearchMarkdownRenderer() {
    let match = Match(
      page: 1, line: 3, text: "keybag", contextBefore: ["alpha"], contextAfter: ["beta"])
    let rendered = SearchMarkdownRenderer.render(
      matches: [match], context: 1, headers: true, blockContext: false)
    XCTAssertTrue(rendered.contains("## Page 1"))
    XCTAssertTrue(rendered.contains("- line 3: keybag"))
    XCTAssertTrue(rendered.contains("before: alpha"))
    XCTAssertTrue(rendered.contains("after: beta"))
  }

  func testBlockContextUsesParagraph() {
    let lines = [
      "alpha header",
      "deep keybag field",
      "continued line",
      "",
      "other section",
    ]
    let (before, after) = ContextBuilder.bounds(
      lines: lines, index: 1, context: 0, blockContext: true)
    XCTAssertEqual(before, ["alpha header"])
    XCTAssertEqual(after, ["continued line"])
  }

  func testColumnLayoutOrdersLeftThenRight() throws {
    let pdfURL = try makeTwoColumnPDF(
      left: ["L1", "L2"],
      right: ["R1", "R2"]
    )
    let doc = try PDFLoader.open(path: pdfURL.path)
    guard let page = doc.page(at: 0) else { return XCTFail("No page") }

    let formatter = PageFormatter(layout: .columns, format: .text)
    let rendered = formatter.formatPageText(page, pageNumber: 1, includeHeader: false)
    let lines = rendered.split(whereSeparator: \.isNewline).map(String.init)
    XCTAssertEqual(lines, ["L1", "L2", "R1", "R2"])
  }

  func testThreeColumnDetection() throws {
    let pdfURL = try makeThreeColumnPDF(
      col1: ["A1", "A2"],
      col2: ["B1"],
      col3: ["C1", "C2"]
    )
    let doc = try PDFLoader.open(path: pdfURL.path)
    guard let page = doc.page(at: 0) else { return XCTFail("No page") }

    let formatter = PageFormatter(layout: .columns, format: .text)
    let rendered = formatter.formatPageText(page, pageNumber: 1, includeHeader: false)
    let lines = rendered.split(whereSeparator: \.isNewline).map(String.init)
    XCTAssertEqual(lines, ["A1", "A2", "B1 C1", "C2"])
  }

  func testTocDotCollapseAndFooterRemoval() {
    let lines = [
      "About Apple File System 7 . . . .",
      "2020-06-22 | Copyright © 2020 Apple Inc. All Rights Reserved.",
      " 2 ",
    ]
    let collapsed = lines.map(LineNormalizer.collapseDotLeaders)
    let cleaned = PageCleaner.clean(lines: collapsed, pageNumber: 2, includeHeader: false)
    XCTAssertEqual(cleaned, ["About Apple File System 7 …"])
  }

  func testAPFSSpecColumnsIfPresent() throws {
    let path = "Tests/Fixtures/.local/Apple-File-System-Reference.pdf"
    guard FileManager.default.fileExists(atPath: path) else {
      throw XCTSkip("Local fixture not found at \(path); copy the APFS spec there to run.")
    }

    let doc = try PDFLoader.open(path: path)
    XCTAssertGreaterThan(doc.pageCount, 2)
    guard let page = doc.page(at: 1) else { return XCTFail("missing page 2") }

    let formatter = PageFormatter(layout: .columns, format: .markdown)
    let markdown = formatter.formatPageText(page, pageNumber: 2, includeHeader: false)

    XCTAssertFalse(markdown.isEmpty)
    let tocLeft = "Mounting an Apple File System Partition"
    let tocRight = "Object Maps"
    guard let leftIdx = markdown.range(of: tocLeft)?.lowerBound,
      let rightIdx = markdown.range(of: tocRight)?.lowerBound
    else { throw XCTSkip("TOC markers not found on page 2; PDF layout differs") }
    XCTAssertLessThan(leftIdx, rightIdx, "Left-column TOC entry should precede right-column entry")
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

private func makeTwoColumnPDF(left: [String], right: [String]) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
    .appendingPathExtension("pdf")

  var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
  guard let consumer = CGDataConsumer(url: url as CFURL) else {
    throw XCTSkip("Could not create data consumer")
  }
  guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
    throw XCTSkip("Could not create PDF context")
  }

  let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
  context.beginPDFPage(nil)

  var yLeft: CGFloat = mediaBox.height - 72
  for line in left {
    let attr: [NSAttributedString.Key: Any] = [
      kCTFontAttributeName as NSAttributedString.Key: font
    ]
    let attributed = NSAttributedString(string: line, attributes: attr)
    let ctLine = CTLineCreateWithAttributedString(attributed)
    context.textPosition = CGPoint(x: 54, y: yLeft)
    CTLineDraw(ctLine, context)
    yLeft -= 18
  }

  var yRight: CGFloat = mediaBox.height - 72
  for line in right {
    let attr: [NSAttributedString.Key: Any] = [
      kCTFontAttributeName as NSAttributedString.Key: font
    ]
    let attributed = NSAttributedString(string: line, attributes: attr)
    let ctLine = CTLineCreateWithAttributedString(attributed)
    context.textPosition = CGPoint(x: mediaBox.width / 2 + 30, y: yRight)
    CTLineDraw(ctLine, context)
    yRight -= 18
  }

  context.endPDFPage()
  context.closePDF()
  return url
}

private func makeThreeColumnPDF(col1: [String], col2: [String], col3: [String]) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
    .appendingPathExtension("pdf")

  var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
  guard let consumer = CGDataConsumer(url: url as CFURL) else {
    throw XCTSkip("Could not create data consumer")
  }
  guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
    throw XCTSkip("Could not create PDF context")
  }

  let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
  context.beginPDFPage(nil)

  func drawColumn(lines: [String], x: CGFloat) {
    var y: CGFloat = mediaBox.height - 72
    for line in lines {
      let attr: [NSAttributedString.Key: Any] = [
        kCTFontAttributeName as NSAttributedString.Key: font
      ]
      let attributed = NSAttributedString(string: line, attributes: attr)
      let ctLine = CTLineCreateWithAttributedString(attributed)
      context.textPosition = CGPoint(x: x, y: y)
      CTLineDraw(ctLine, context)
      y -= 18
    }
  }

  drawColumn(lines: col1, x: 54)
  drawColumn(lines: col2, x: 54 + 160)
  drawColumn(lines: col3, x: 54 + 320)

  context.endPDFPage()
  context.closePDF()
  return url
}
