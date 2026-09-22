import SwiftUI
import UniformTypeIdentifiers
import OpenJWCCore

/// JSON 文本 FileDocument（fileExporter/fileImporter 统一载体）。
struct JsonTextDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    static let writableContentTypes: [UTType] = [.json]

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        self.text = String(data: data, encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// 导入文件读取 + 解析（菜单/空态/表选择三入口共用）。
enum TimetableImport {
    /// 读取 JSON 文件并解析；失败抛出（ParseError 带具体原因，读文件失败为 Cocoa 错误）。
    static func parseFile(at url: URL) throws -> TimetableJson.ParseResult {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try TimetableJson.parseExternal(json: text)
    }
}

/// 导出文件名净化（spec：`\ / : * ? " < > |` 与空白 → `_`；空回退 `timetable`）。
enum ExportNaming {
    static func sanitizedFileName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|").union(.whitespacesAndNewlines)
        var cleaned = ""
        for scalar in raw.unicodeScalars {
            cleaned.unicodeScalars.append(invalid.contains(scalar) ? "_" : scalar)
        }
        return cleaned.isEmpty ? "timetable" : cleaned
    }
}
