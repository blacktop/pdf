import ArgumentParser
import Foundation
import PDFKit

enum TextFormat: String, CaseIterable, ExpressibleByArgument {
  case text
  case markdown
}

enum LayoutMode: String, CaseIterable, ExpressibleByArgument {
  case plain
  case smart
  case columns
}

struct PageFormatter {
  let layout: LayoutMode
  let format: TextFormat

  func formatPageText(_ page: PDFPage, pageNumber: Int, includeHeader: Bool) -> String {
    let rawLines = ColumnExtractor.lines(from: page, layout: layout)
    let normalized = LineNormalizer.normalize(lines: rawLines, layout: layout)
    let dotCollapsed = normalized.map(LineNormalizer.collapseDotLeaders)
    let cleaned = PageCleaner.clean(
      lines: dotCollapsed, pageNumber: pageNumber, includeHeader: includeHeader)
    let rendered: String

    switch format {
    case .text:
      rendered = cleaned.joined(separator: "\n")
    case .markdown:
      rendered = Markdownifier.render(lines: cleaned)
    }

    guard includeHeader else { return rendered }

    switch format {
    case .text:
      return "--- PAGE \(pageNumber) ---\n" + rendered
    case .markdown:
      return "## Page \(pageNumber)\n\n" + rendered
    }
  }
}

enum LineNormalizer {
  static func normalize(rawText: String, layout: LayoutMode) -> [String] {
    let lines = rawText.split(whereSeparator: \.isNewline).map(String.init)
    guard layout == .smart else { return lines }
    return normalize(lines: lines, layout: layout)
  }

  static func normalize(lines: [String], layout: LayoutMode) -> [String] {
    guard layout != .plain else { return lines }

    var result: [String] = []
    var idx = 0

    while idx < lines.count {
      var line = lines[idx]
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      // Empty lines stay as separators.
      if trimmed.isEmpty {
        result.append("")
        idx += 1
        continue
      }

      // Hyphenated line breaks: join if the next line continues the word.
      if line.hasSuffix("-"), idx + 1 < lines.count {
        let next = lines[idx + 1].trimmingCharacters(in: .whitespaces)
        if let first = next.first, first.isLowercase {
          line.removeLast()
          line.append(next)
          idx += 2
          result.append(line)
          continue
        }
      }

      // Indent-based soft wrap: join lines that are likely the same paragraph.
      if idx + 1 < lines.count {
        let nextLine = lines[idx + 1]
        let nextTrim = nextLine.trimmingCharacters(in: .whitespaces)
        if !nextTrim.isEmpty, nextLine.hasPrefix("  "),
          !line.trimmingCharacters(in: .whitespaces).isEmpty
        {
          line.append(" " + nextTrim)
          idx += 2
          result.append(line)
          continue
        }
      }

      result.append(line)
      idx += 1
    }

    return result
  }

  static func paragraphBounds(lines: [String], index: Int) -> (before: [String], after: [String]) {
    var before: [String] = []
    var i = index - 1
    while i >= 0 {
      if lines[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
      before.append(lines[i])
      i -= 1
    }
    before.reverse()

    var after: [String] = []
    var j = index + 1
    while j < lines.count {
      if lines[j].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
      after.append(lines[j])
      j += 1
    }

    return (before, after)
  }

  static func collapseDotLeaders(_ line: String) -> String {
    // collapse runs of 3+ dots or dot-space leaders, but avoid version numbers like 1.2.3
    var text = line.replacingOccurrences(
      of: #"(\.{3,})"#, with: " … ", options: .regularExpression)
    text = text.replacingOccurrences(
      of: #"(\.\s+){3,}"#, with: " … ", options: .regularExpression)
    text = text.replacingOccurrences(
      of: #" … \."#, with: " …", options: .regularExpression)
    text = text.replacingOccurrences(
      of: #"\s+\.\s*$"#, with: "", options: .regularExpression)
    while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
    return text.trimmingCharacters(in: .whitespaces)
  }
}

enum PageCleaner {
  static func clean(lines: [String], pageNumber: Int, includeHeader: Bool) -> [String] {
    lines
      .filter {
        !isFooter($0) && !isPageNumberLine($0, pageNumber: pageNumber, includeHeader: includeHeader)
      }
  }

  private static func isFooter(_ line: String) -> Bool {
    let lower = line.lowercased()
    return lower.contains("copyright") && lower.contains("apple")
  }

  private static func isPageNumberLine(_ line: String, pageNumber: Int, includeHeader: Bool) -> Bool
  {
    // Only strip when headers are OFF and line is a short standalone page number.
    guard !includeHeader else { return false }
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.count <= 3, let value = Int(trimmed) else { return false }
    return value == pageNumber
  }
}

enum ContextBuilder {
  static func bounds(
    lines: [String], index: Int, context: Int, blockContext: Bool
  ) -> ([String], [String]) {
    if blockContext {
      return LineNormalizer.paragraphBounds(lines: lines, index: index)
    }

    guard context > 0 else { return ([], []) }

    let lowerBound = max(0, index - context)
    let upperBound = min(lines.count - 1, index + context)
    let before = lowerBound < index ? Array(lines[lowerBound..<index]) : []
    let afterStart = index + 1
    let after = afterStart <= upperBound ? Array(lines[afterStart...upperBound]) : []
    return (before, after)
  }
}

enum Markdownifier {
  static func render(lines: [String]) -> String {
    var output: [String] = []
    var inCode = false
    var bufferedTable: [[String]] = []

    func makeRow(_ columns: [String]) -> String {
      let trimmed = columns.map { $0.trimmingCharacters(in: .whitespaces) }
      return "| " + trimmed.joined(separator: " | ") + " |"
    }

    func flushTable() {
      guard !bufferedTable.isEmpty else { return }
      guard bufferedTable.count >= 2 else {
        // Not enough rows for a table; emit as plain lines.
        bufferedTable.forEach { output.append($0.joined(separator: " ")) }
        bufferedTable.removeAll()
        return
      }
      let header = bufferedTable[0]
      let separators = header.map { _ in "---" }
      output.append(makeRow(header))
      output.append(makeRow(separators))
      for row in bufferedTable.dropFirst() {
        output.append(makeRow(row))
      }
      bufferedTable.removeAll()
    }

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      if trimmed.isEmpty {
        flushTable()
        output.append("")
        continue
      }

      if let cols = splitColumns(trimmed: trimmed) {
        bufferedTable.append(cols)
        continue
      } else {
        flushTable()
      }

      if let heading = detectHeading(trimmed: trimmed) {
        if inCode {
          output.append("```")
          inCode = false
        }
        output.append("### \(heading)")
        continue
      }

      if let bullet = detectBullet(trimmed: trimmed) {
        if inCode {
          output.append("```")
          inCode = false
        }
        output.append("- \(bullet)")
        continue
      }

      let isCode = detectCode(trimmed: trimmed, original: line)

      if isCode {
        if !inCode {
          output.append("```")
          inCode = true
        }
        output.append(line.trimmingCharacters(in: .whitespaces))
      } else {
        if inCode {
          output.append("```")
          inCode = false
        }
        output.append(trimmed)
      }
    }

    flushTable()
    if inCode { output.append("```") }
    return output.joined(separator: "\n")
  }

  private static func detectHeading(trimmed: String) -> String? {
    guard trimmed.count <= 80 else { return nil }

    // All-caps headings or short label-with-colon.
    let letters = CharacterSet.letters
    let hasLetters = trimmed.unicodeScalars.contains { letters.contains($0) }
    let isAllCaps = trimmed == trimmed.uppercased()
    let isLabel = trimmed.hasSuffix(":") && trimmed.split(separator: " ").count <= 8

    guard hasLetters, isAllCaps || isLabel else { return nil }
    return headingCased(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":")))
  }

  private static func detectBullet(trimmed: String) -> String? {
    let patterns = ["•", "∙", "-", "–", "—"]
    for prefix in patterns {
      if trimmed.hasPrefix(prefix + " ") {
        return String(trimmed.dropFirst(prefix.count + 1))
      }
    }

    if let range = trimmed.range(of: #"^\d+[\.\)]\s+"#, options: .regularExpression) {
      let content = trimmed[range.upperBound...]
      return String(content)
    }

    return nil
  }

  private static func detectCode(trimmed: String, original: String) -> Bool {
    if original.hasPrefix("    ") || original.hasPrefix("\t") { return true }
    if trimmed.contains("{") || trimmed.contains("}") { return true }
    if trimmed.contains("=") || trimmed.contains(";") { return true }
    return false
  }

  private static func splitColumns(trimmed: String) -> [String]? {
    // Heuristic: treat runs of 2+ spaces as column gaps.
    var columns: [String] = []
    var current = ""
    var spaceRun = 0

    func flush() {
      let value = current.trimmingCharacters(in: .whitespaces)
      if !value.isEmpty {
        columns.append(value)
      }
      current = ""
    }

    for char in trimmed {
      if char == " " {
        spaceRun += 1
        if spaceRun >= 2 {
          flush()
        }
      } else {
        if spaceRun > 0 && !current.isEmpty {
          current.append(" ")
        }
        spaceRun = 0
        current.append(char)
      }
    }
    flush()

    return columns.count >= 2 ? columns : nil
  }

  private static func headingCased(_ text: String) -> String {
    return
      text
      .lowercased()
      .split(separator: " ")
      .map { $0.prefix(1).uppercased() + $0.dropFirst() }
      .joined(separator: " ")
  }
}

enum SearchMarkdownRenderer {
  static func render(matches: [Match], context: Int, headers: Bool, blockContext: Bool) -> String {
    guard !matches.isEmpty else { return "_No matches found._" }

    var output: [String] = []
    var currentPage: Int?

    for match in matches {
      if headers && currentPage != match.page {
        currentPage = match.page
        output.append("## Page \(match.page)")
      }

      output.append("- line \(match.line): \(match.text)")

      if (context > 0 || blockContext) && !match.contextBefore.isEmpty {
        for line in match.contextBefore {
          output.append("  - before: \(line.trimmingCharacters(in: .whitespaces))")
        }
      }
      if (context > 0 || blockContext) && !match.contextAfter.isEmpty {
        for line in match.contextAfter {
          output.append("  - after: \(line.trimmingCharacters(in: .whitespaces))")
        }
      }
    }

    return output.joined(separator: "\n")
  }
}
