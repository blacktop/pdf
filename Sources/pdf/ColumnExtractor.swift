import Foundation
import PDFKit

struct ColumnExtractor {
  struct PositionedWord {
    let text: String
    let bounds: CGRect
  }

  static func lines(from page: PDFPage, layout: LayoutMode) -> [String] {
    switch layout {
    case .plain, .smart:
      let raw = page.string ?? ""
      return raw.split(whereSeparator: \.isNewline).map(String.init)
    case .columns:
      return orderedLines(page: page)
    }
  }

  private static func orderedLines(page: PDFPage) -> [String] {
    guard let full = page.selection(for: page.bounds(for: .mediaBox)) else {
      return page.string?.split(whereSeparator: \.isNewline).map(String.init) ?? []
    }
    var words: [PositionedWord] = []
    for lineSel in full.selectionsByLine() {
      let parts = splitWords(selection: lineSel)
      if parts.count == 1, parts.first === lineSel {
        // synthesize words from text if per-word selection unavailable
        words.append(contentsOf: synthesizeWords(from: lineSel, page: page))
      } else {
        words.append(
          contentsOf: parts.compactMap { sel -> PositionedWord? in
            guard let str = sel.string?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
              !str.isEmpty
            else { return nil as PositionedWord? }
            let bounds = sel.bounds(for: page)
            return PositionedWord(text: str, bounds: bounds)
          })
      }
    }
    guard words.count >= 2 else { return words.map(\.text) }

    let columns = clusterColumns(items: words)
    let orderedColumns = columns.sorted { $0.first?.bounds.minX ?? 0 < $1.first?.bounds.minX ?? 0 }
    var lines: [String] = []
    for column in orderedColumns {
      let sorted = sortByReadingOrder(column)
      lines.append(contentsOf: groupIntoLines(sorted))
    }
    return lines
  }

  private static func clusterColumns(items: [PositionedWord]) -> [[PositionedWord]] {
    let sorted = items.sorted { $0.bounds.minX < $1.bounds.minX }
    guard sorted.count >= 2 else { return [sorted] }

    let uniqueStarts = Array(Set(sorted.map { $0.bounds.minX })).sorted()
    var startGaps: [CGFloat] = []
    for i in 1..<uniqueStarts.count {
      startGaps.append(uniqueStarts[i] - uniqueStarts[i - 1])
    }
    let positiveGaps = startGaps.filter { $0 > 0 }
    guard let medianGap = median(positiveGaps), medianGap > 0 else { return [sorted] }

    // Use a scaled gutter threshold based on observed gaps and span of all words.
    let minX = items.map { $0.bounds.minX }.min() ?? 0
    let maxX = items.map { $0.bounds.maxX }.max() ?? 0
    let span = maxX - minX
    let dynamic = medianGap * 0.8
    let scaled = span > 0 ? max(dynamic, span * 0.04) : dynamic
    let threshold: CGFloat = max(24, min(scaled, 180))
    var splits: [CGFloat] = []
    for i in 1..<sorted.count {
      let gap = sorted[i].bounds.minX - sorted[i - 1].bounds.maxX
      if gap > threshold {
        let split = sorted[i - 1].bounds.maxX + gap / 2
        splits.append(split)
      }
    }

    guard !splits.isEmpty else { return [sorted] }

    var buckets: [[PositionedWord]] = Array(repeating: [], count: splits.count + 1)
    for word in items {
      let mid = word.bounds.midX
      let bucket = splits.firstIndex { mid < $0 } ?? splits.count
      buckets[bucket].append(word)
    }
    return buckets
  }

  private static func sortByReadingOrder(_ bucket: [PositionedWord]) -> [PositionedWord] {
    bucket.sorted { a, b in
      if abs(a.bounds.minY - b.bounds.minY) < 1.0 {
        return a.bounds.minX < b.bounds.minX
      }
      return a.bounds.minY > b.bounds.minY
    }
  }

  private static func median(_ values: [CGFloat]) -> CGFloat? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    if sorted.count % 2 == 0 {
      return (sorted[mid - 1] + sorted[mid]) / 2
    } else {
      return sorted[mid]
    }
  }

  private static func groupIntoLines(_ words: [PositionedWord]) -> [String] {
    var lines: [[PositionedWord]] = []
    let yTolerance: CGFloat = 3
    let gapThreshold: CGFloat = 80  // avoid splitting wide code/table lines; columns are split earlier

    for word in words {
      if lines.isEmpty {
        lines.append([word])
        continue
      }

      if var last = lines.popLast(), let anchor = last.last {
        let sameLine = abs(anchor.bounds.midY - word.bounds.midY) < yTolerance
        if sameLine {
          let gap = word.bounds.minX - anchor.bounds.maxX
          if gap > gapThreshold {
            lines.append(last)
            lines.append([word])
          } else {
            last.append(word)
            lines.append(last)
          }
        } else {
          lines.append(last)
          lines.append([word])
        }
      }
    }

    return lines.map { line in
      line.map(\.text).joined(separator: " ")
    }
  }

  private static func splitWords(selection: PDFSelection) -> [PDFSelection] {
    let selector = NSSelectorFromString("selectionsByWord")
    if (selection as AnyObject).responds(to: selector),
      let obj = (selection as AnyObject).perform(selector)?.takeUnretainedValue() as? [PDFSelection]
    {
      return obj
    }
    return [selection]
  }

  private static func synthesizeWords(from selection: PDFSelection, page: PDFPage)
    -> [PositionedWord]
  {
    guard let text = selection.string?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
      !text.isEmpty
    else { return [] }

    let tokens = text.split(separator: " ")
    guard tokens.count > 1 else {
      return [PositionedWord(text: text, bounds: selection.bounds(for: page))]
    }

    let bounds = selection.bounds(for: page)
    let avgCharWidth = bounds.width / CGFloat(max(text.count, 1))
    var x = bounds.minX
    var result: [PositionedWord] = []

    for token in tokens {
      let tokenWidth = max(avgCharWidth * CGFloat(token.count), 10)
      let rect = CGRect(x: x, y: bounds.minY, width: tokenWidth, height: bounds.height)
      result.append(PositionedWord(text: String(token), bounds: rect))
      x += tokenWidth + avgCharWidth  // add approximate space width
      if x > bounds.maxX { break }  // avoid spilling far outside selection
    }
    return result
  }
}
