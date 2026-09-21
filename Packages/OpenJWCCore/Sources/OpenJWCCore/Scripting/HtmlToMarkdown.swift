import Foundation
import SwiftSoup

/// 精简版 HTML → Markdown，逐行直译 Android `HtmlToMarkdown.kt`
/// （对齐 JwcCrawler 里 `htmd` 的用法：跳过模板节点、保留结构、相对链接转绝对）。
public enum HtmlToMarkdown {

    private static let skipTags: Set<String> = [
        "script", "style", "colgroup", "col", "noscript", "head", "meta", "link",
        "title", "iframe", "svg", "form", "input", "button", "select", "option",
    ]

    private static let blockTags: Set<String> = [
        "p", "div", "section", "article", "figure", "figcaption", "dd", "dt",
        "header", "footer", "main", "aside", "nav", "center", "fieldset",
    ]

    static let spaces = try? NSRegularExpression(pattern: "[ \\t\\u00a0]{2,}")
    static let orderedItem = try? NSRegularExpression(pattern: "^\\d+[.)] ")

    /// 把 HTML 片段转成 Markdown；baseUrl 用于把相对链接转成绝对链接。
    public static func convert(_ html: String, baseUrl: String? = nil) -> String {
        guard !html.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        let cleaned = html
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
        guard let body = try? SwiftSoup.parseBodyFragment(cleaned).body() else { return "" }
        let raw = (try? body.getChildNodes().map { renderNode($0, baseUrl) }.joined()) ?? ""
        return cleanup(raw)
    }

    private static func renderNode(_ node: Node, _ base: String?) -> String {
        if let text = node as? TextNode {
            return (try? text.text()) ?? ""
        }
        if let element = node as? Element {
            return renderElement(element, base)
        }
        return ""
    }

    private static func renderChildren(_ element: Element, _ base: String?) -> String {
        let children = (try? element.getChildNodes()) ?? []
        return children.map { renderNode($0, base) }.joined()
    }

    /// 只渲染内联内容（表格单元格、标题、列表项），换行折叠成空格。
    private static func inline(_ element: Element, _ base: String?) -> String {
        renderChildren(element, base).replacingOccurrences(of: "\n", with: " ")
    }

    private static func renderElement(_ element: Element, _ base: String?) -> String {
        guard let tag = (try? element.tagName())?.lowercased() else { return "" }
        if skipTags.contains(tag) { return "" }

        switch tag {
        case "br":
            return "\n"
        case "hr":
            return "\n\n---\n\n"
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let text = inline(element, base).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return "" }
            let level = tag.suffix(1)
            return "\n\n\(String(repeating: "#", count: Int(level) ?? 1)) \(text)\n\n"
        case "strong", "b":
            return wrap(element, base, "**")
        case "em", "i":
            return wrap(element, base, "*")
        case "del", "s", "strike":
            return wrap(element, base, "~~")
        case "code", "tt":
            let parentTag = (try? element.parent()?.tagName())?.lowercased() ?? ""
            if parentTag == "pre" {
                return inline(element, base)
            }
            return "`\(inline(element, base).trimmingCharacters(in: .whitespaces))`"
        case "pre":
            // SwiftSoup 无 wholeText()；pre 内换行用原始文本节点拼接近似
            let whole = (try? element.text()) ?? ""
            return "\n\n```\n\(whole.trimmingCharacters(in: .whitespacesAndNewlines))\n```\n\n"
        case "blockquote":
            let text = renderChildren(element, base).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return "" }
            let quoted = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }
                .joined(separator: "\n")
            return "\n\n\(quoted)\n\n"
        case "a":
            return link(element, base)
        case "img":
            return image(element, base)
        case "ul", "ol":
            return list(element, base, ordered: tag == "ol")
        case "table":
            return table(element, base)
        // 表格相关标签由 table() 统一处理
        case "tr", "td", "th", "thead", "tbody", "tfoot", "caption":
            return ""
        default:
            if blockTags.contains(tag) {
                // 块级容器用结构性渲染，保留内部段落/列表换行（inline 会把正文压成一行）
                let text = renderChildren(element, base).trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? "" : "\n\n\(text)\n\n"
            }
            return renderChildren(element, base)
        }
    }

    private static func wrap(_ element: Element, _ base: String?, _ marker: String) -> String {
        let text = inline(element, base).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "" : "\(marker)\(text)\(marker)"
    }

    private static func link(_ element: Element, _ base: String?) -> String {
        let text = inline(element, base).trimmingCharacters(in: .whitespaces)
        let href = absolute((try? element.attr("href")) ?? "", base) ?? ""
        if href.contains("icon_") { return text }
        return text.isEmpty ? href : "[\(text)](\(href))"
    }

    private static func image(_ element: Element, _ base: String?) -> String {
        var raw = (try? element.attr("src")) ?? ""
        if raw.isEmpty { raw = (try? element.attr("pdfsrc")) ?? "" }
        guard let src = absolute(raw, base) else { return "" }
        if src.contains("icon_") { return "" }
        var alt = (try? element.attr("alt")) ?? ""
        if alt.isEmpty { alt = (try? element.attr("title")) ?? "" }
        return "![\(alt)](\(src))"
    }

    private static func list(_ element: Element, _ base: String?, ordered: Bool) -> String {
        let children = (try? element.children())?.array() ?? []
        let items = children.filter { ($0.tagName() ?? "") == "li" }
        if items.isEmpty { return "" }
        let body = items.enumerated().map { index, li -> String in
            let marker = ordered ? "\(index + 1). " : "- "
            let text = renderChildren(li, base)
                .replacingOccurrences(of: "\n", with: " ")
                .collapseSpaces()
                .trimmingCharacters(in: .whitespaces)
            return marker + text
        }.joined(separator: "\n")
        return "\n\n\(body)\n\n"
    }

    /// 表格 → Markdown 表格（合并单元格拍平，只保留文字）。
    private static func table(_ element: Element, _ base: String?) -> String {
        let allRows = (try? element.select("tr").array()) ?? []
        let rows = allRows.filter { !((try? $0.select("td, th").array()) ?? []).isEmpty }
        if rows.isEmpty { return "" }
        let matrix: [[String]] = rows.map { row in
            ((try? row.select("td, th").array()) ?? []).map { cell in
                inline(cell, base)
                    .replacingOccurrences(of: "|", with: "\\|")
                    .collapseSpaces()
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        let columns = matrix.map(\.count).max() ?? 0
        if columns == 0 { return "" }
        let padded = matrix.map { row in row + Array(repeating: "", count: columns - row.count) }
        var out = "\n\n| \(padded[0].joined(separator: " | ")) |\n"
        out += "| \(Array(repeating: "---", count: columns).joined(separator: " | ")) |\n"
        for row in padded.dropFirst() {
            out += "| \(row.joined(separator: " | ")) |\n"
        }
        out += "\n"
        return out
    }

    private static func absolute(_ raw: String, _ base: String?) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return nil }
        let lower = value.lowercased()
        if lower.hasPrefix("javascript:") { return nil }
        if value.hasPrefix("#") { return nil }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return value }
        guard let base, !base.isEmpty else { return value }
        guard let url = URL(string: base), let resolved = URL(string: value, relativeTo: url) else {
            return value
        }
        return resolved.absoluteString
    }

    private static func cleanup(_ raw: String) -> String {
        let lines = raw
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .collapseSpaces()
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var result = ""
        for (index, line) in lines.enumerated() {
            result += line
            if index < lines.count - 1 {
                let next = lines[index + 1]
                let tight = (line.hasPrefix("|") && next.hasPrefix("|"))
                    || (isListItem(line) && isListItem(next))
                    || (line.hasPrefix("> ") && next.hasPrefix("> "))
                result += tight ? "\n" : "\n\n"
            }
        }
        return result
            .replacingOccurrences(of: "****", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isListItem(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ")
        || (orderedItem?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil)
    }
}

extension String {
    /// 折叠连续空白（对齐 Android SPACES 正则 `[ \t\u00a0]{2,}` → " "）。
    func collapseSpaces() -> String {
        guard let spaces = HtmlToMarkdown.spaces else { return self }
        let range = NSRange(startIndex..., in: self)
        return spaces.stringByReplacingMatches(in: self, options: [], range: range, withTemplate: " ")
    }
}
