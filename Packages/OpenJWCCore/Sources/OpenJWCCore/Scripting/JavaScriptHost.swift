import Foundation
import CryptoKit
import JavaScriptCore
import SwiftSoup

/// JavaScriptCore 脚本宿主（对位 Android `QuickJsScriptHost`）。
///
/// 脚本契约：
/// ```js
/// // @id xxx  @domains example.com
/// function fetchNotices() {
///   const page = http.get("https://example.com/list.htm");
///   const rows = JSON.parse(dom.query(page, "li.news"));
///   return JSON.stringify(rows.map(r => ({ id: util.sha256(r.attrs.href), ... })));
/// }
/// ```
/// 桥接全局名 `http` / `dom` / `util` / `params` / `console` / `report`。
///
/// 超时模型与 Android 同构：JSC 无中断 API，worker 线程同步跑完，
/// 等待方超时后放弃该 worker（线程自行结束，不阻塞后续运行）。
public final class JavaScriptHost: @unchecked Sendable {
    public static let defaultUserAgent = "OpenJWC/1.0 (+https://github.com/OpenJWC)"
    /// 静态校验超时（不含真实网络请求）。
    private static let validateTimeoutMs = 5_000

    private let userAgent: String
    private let queue = DispatchQueue(label: "openjwc.jsc-host", attributes: .concurrent)

    public init(userAgent: String = JavaScriptHost.defaultUserAgent) {
        self.userAgent = userAgent
    }

    // MARK: - 运行

    public func run(
        script: String,
        sandbox: ScriptSandbox,
        params: ScriptRunParams = ScriptRunParams(),
        onLog: (@Sendable (String) -> Void)? = nil,
        onProgress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> ScriptOutcome {
        // 竞速：worker（GCD 线程，跑完即弃）vs 超时哨兵。
        // 超时后 worker 被放弃（线程自行跑到结束），等价 Android Future.cancel 语义。
        try await withThrowingTaskGroup(of: ScriptOutcome.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    let workItem = DispatchWorkItem {
                        continuation.resume(with: Result {
                            try self.executeBlocking(script, sandbox, params, onLog, onProgress)
                        })
                    }
                    self.queue.async(execute: workItem)
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(sandbox.timeoutMs) * 1_000_000)
                throw ScriptError.timeout
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// 静态校验：无真实桥接的沙箱求值，检查 `fetchNotices` 是否定义。
    /// 返回错误信息；脚本合法时返回 nil。
    public func validate(script: String) -> String? {
        let box = StringBox()
        let workItem = DispatchWorkItem {
            box.complete(Result { try self.validateBlocking(script: script) })
        }
        queue.async(execute: workItem)
        let semaphore = DispatchSemaphore(value: 0)
        workItem.notify(queue: .global()) { semaphore.signal() }
        let waited = semaphore.wait(timeout: .now() + .milliseconds(Self.validateTimeoutMs))
        if waited == .timedOut {
            workItem.cancel()
            return "脚本校验超时"
        }
        return try? box.get()
    }

    private func validateBlocking(script: String) throws -> String? {
        guard let context = JSContext() else { throw ScriptError.execution("JSContext 创建失败") }
        context.setObject(StubHttpBridge(), forKeyedSubscript: "http" as NSString)
        context.setObject(StubHtmlBridge(), forKeyedSubscript: "dom" as NSString)
        context.setObject(StubUtilBridge(), forKeyedSubscript: "util" as NSString)
        context.setObject(ConsoleBridge(onLog: nil), forKeyedSubscript: "console" as NSString)
        context.setObject(StubParamsBridge(), forKeyedSubscript: "params" as NSString)
        context.setObject(StubReportBridge(), forKeyedSubscript: "report" as NSString)
        context.evaluateScript(script)
        let type = context.evaluateScript("typeof fetchNotices")?.toString()
        return type == "function" ? nil : "脚本必须定义 function fetchNotices()"
    }

    private func executeBlocking(
        _ script: String,
        _ sandbox: ScriptSandbox,
        _ params: ScriptRunParams,
        _ onLog: (@Sendable (String) -> Void)?,
        _ onProgress: (@Sendable (Double, String) -> Void)?
    ) throws -> ScriptOutcome {
        guard let context = JSContext() else { throw ScriptError.execution("JSContext 创建失败") }
        let report = ReportBridge(onLog: onLog, onProgress: onProgress)
        context.setObject(HttpBridge(sandbox: sandbox, userAgent: userAgent), forKeyedSubscript: "http" as NSString)
        context.setObject(HtmlBridge(), forKeyedSubscript: "dom" as NSString)
        context.setObject(UtilBridge(), forKeyedSubscript: "util" as NSString)
        context.setObject(ConsoleBridge(onLog: onLog), forKeyedSubscript: "console" as NSString)
        context.setObject(ParamsBridge(params: params), forKeyedSubscript: "params" as NSString)
        context.setObject(report, forKeyedSubscript: "report" as NSString)

        // 脚本与调用放在同一次 evaluate 中，保证函数声明进入全局作用域
        let combined = script + "\n;JSON.stringify(fetchNotices());"
        let result = context.evaluateScript(combined)

        if let exception = context.exception {
            throw ScriptError.execution(exception.toString())
        }
        guard let text = result?.toString(),
              !text.isEmpty, text != "null", text != "undefined" else {
            return ScriptOutcome(
                scanned: report.scanned, skipped: report.skipped, failed: report.failed,
                noContent: report.noContent, restricted: report.restricted,
                skippedOld: report.skippedOld, skippedDuplicate: report.skippedDuplicate,
                skippedKnown: report.skippedKnown, warnings: report.warnings
            )
        }
        let decoder = JSONDecoder()
        do {
            // 宿主模板会 JSON.stringify(fetchNotices())；若脚本内部已 return JSON.stringify(...)，
            // 得到的是双层字符串化文本——先剥一层（对齐 Android kotlinx isLenient 的宽容行为）。
            var payload = text
            if payload.hasPrefix("\"") {
                if let inner = try? decoder.decode(String.self, from: Data(payload.utf8)) {
                    payload = inner
                }
            }
            let notices = try decoder.decode([ScriptNotice].self, from: Data(payload.utf8))
            return ScriptOutcome(
                notices: notices,
                scanned: report.scanned, skipped: report.skipped, failed: report.failed,
                noContent: report.noContent, restricted: report.restricted,
                skippedOld: report.skippedOld, skippedDuplicate: report.skippedDuplicate,
                skippedKnown: report.skippedKnown, warnings: report.warnings
            )
        } catch {
            throw ScriptError.execution("脚本返回的资讯解析失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - 结果搬运

private final class OutcomeBox: @unchecked Sendable {
    private var result: Result<ScriptOutcome, Error>?
    func complete(_ r: Result<ScriptOutcome, Error>) { result = r }
    func get() throws -> ScriptOutcome {
        guard let result else { throw ScriptError.execution("脚本 worker 无结果返回") }
        return try result.get()
    }
}

private final class StringBox: @unchecked Sendable {
    private var result: Result<String?, Error>?
    func complete(_ r: Result<String?, Error>) { result = r }
    func get() throws -> String? {
        guard let result else { throw ScriptError.execution("校验 worker 无结果返回") }
        return try result.get()
    }
}

// MARK: - 桥（JSExport）

/// HTTP 桥：**同步阻塞**（JSC evaluate 是同步的；worker 线程内信号量等待）。
@objc protocol ScriptHttpBridgeJS: JSExport {
    func get(_ url: String) -> String
    func post(_ url: String, _ body: String, _ contentType: String) -> String
}

final class HttpBridge: NSObject, ScriptHttpBridgeJS {
    private let sandbox: ScriptSandbox
    private let userAgent: String

    init(sandbox: ScriptSandbox, userAgent: String) {
        self.sandbox = sandbox
        self.userAgent = userAgent
    }

    func get(_ url: String) -> String { execute(url, method: "GET", body: nil, contentType: nil) }

    func post(_ url: String, _ body: String, _ contentType: String) -> String {
        execute(url, method: "POST",
                body: body.isEmpty ? nil : body,
                contentType: contentType.isEmpty ? "text/plain; charset=utf-8" : contentType)
    }

    private func execute(_ url: String, method: String, body: String?, contentType: String?) -> String {
        do {
            try sandbox.checkUrl(url)
            try sandbox.onHttpCall()
            guard let requestURL = URL(string: url) else {
                throw ScriptError.execution("非法 URL: \(url)")
            }
            var request = URLRequest(url: requestURL)
            request.httpMethod = method
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            if let body {
                request.httpBody = Data(body.utf8)
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
            // 同步等待（JSC 桥必须同步返回）；worker 超时由宿主层放弃线程兜底
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var payload: Result<String, Error> = .failure(
                ScriptError.execution("no response")
            )
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                defer { semaphore.signal() }
                if let error {
                    payload = .failure(ScriptError.execution("HTTP 失败: \(error.localizedDescription)"))
                    return
                }
                guard let http = response as? HTTPURLResponse, let data else {
                    payload = .failure(ScriptError.execution("HTTP 无响应 \(url)"))
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    payload = .failure(ScriptError.execution("HTTP \(http.statusCode) \(url)"))
                    return
                }
                let text = String(data: data, encoding: .utf8) ?? ""
                do { try self.sandbox.onBytes(text.count) } catch {
                    payload = .failure(error); return
                }
                payload = .success(text)
            }
            task.resume()
            semaphore.wait()
            return try payload.get()
        } catch let error as ScriptError {
            JSCBridgeError.raise(error)
            return ""
        } catch {
            JSCBridgeError.raise(.execution(error.localizedDescription))
            return ""
        }
    }
}

/// HTML 解析桥（SwiftSoup = Jsoup 移植，选择器语法一致）。
@objc protocol ScriptHtmlBridgeJS: JSExport {
    func query(_ html: String, _ selector: String) -> String
    func text(_ html: String, _ selector: String) -> String
    func attr(_ html: String, _ selector: String, _ name: String) -> String
    func markdown(_ html: String, _ selector: String, _ baseUrl: String) -> String
}

final class HtmlBridge: NSObject, ScriptHtmlBridgeJS {
    func query(_ html: String, _ selector: String) -> String {
        do {
            let doc = try parse(html)
            let elements: [Element]
            if selector.isEmpty {
                elements = try doc.getAllElements().array()
            } else {
                elements = try doc.select(selector).array()
            }
            var array: [[String: Any]] = []
            array.reserveCapacity(elements.count)
            for element in elements {
                var attrs: [String: String] = [:]
                if let list = try? element.getAttributes() {
                    for attribute in list {
                        attrs[attribute.getKey()] = attribute.getValue()
                    }
                }
                let tag: String = (try? element.tagName()) ?? ""
                let text: String = (try? element.text()) ?? ""
                let outer: String = (try? element.outerHtml()) ?? ""
                array.append(["tag": tag, "text": text, "html": outer, "attrs": attrs])
            }
            return toJsonString(array)
        } catch {
            JSCBridgeError.raise(.execution("dom.query 失败: \(error.localizedDescription)"))
            return "[]"
        }
    }

    func text(_ html: String, _ selector: String) -> String {
        guard let doc = try? parse(html), let element = try? doc.select(selector).first() else { return "" }
        return (try? element.text()) ?? ""
    }

    func attr(_ html: String, _ selector: String, _ name: String) -> String {
        guard let doc = try? parse(html), let element = try? doc.select(selector).first() else { return "" }
        return (try? element.attr(name)) ?? ""
    }

    func markdown(_ html: String, _ selector: String, _ baseUrl: String) -> String {
        guard let doc = try? parse(html), let element = try? doc.select(selector).first() else { return "" }
        let fragment = (try? element.outerHtml()) ?? ""
        return HtmlToMarkdown.convert(fragment, baseUrl: baseUrl.isEmpty ? nil : baseUrl)
    }

    /// 行片段（tr/td/th）需要包一层 table，否则会被 HTML 解析器丢弃。
    private func parse(_ html: String) throws -> Document {
        let trimmed = html.drop(while: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
        let lower = trimmed.prefix(4).lowercased()
        if lower.hasPrefix("<tr") || lower.hasPrefix("<td") || lower.hasPrefix("<th") {
            return try SwiftSoup.parse("<table><tbody>\(html)</tbody></table>")
        }
        return try SwiftSoup.parseBodyFragment(html)
    }

    private func toJsonString(_ value: [[String: Any]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }
}

/// 通用工具桥。时间戳用 Double 毫秒（JS number）。
@objc protocol ScriptUtilBridgeJS: JSExport {
    func sha256(_ text: String) -> String
    func resolveUrl(_ base: String, _ relative: String) -> String
    func now() -> Double
}

final class UtilBridge: NSObject, ScriptUtilBridgeJS {
    func sha256(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func resolveUrl(_ base: String, _ relative: String) -> String {
        guard let url = URL(string: base),
              let resolved = URL(string: relative, relativeTo: url) else {
            return relative
        }
        return resolved.absoluteString
    }

    func now() -> Double {
        Double(Date().timeIntervalSince1970 * 1000)
    }
}

/// 运行参数桥。
@objc protocol ScriptParamsBridgeJS: JSExport {
    func crawlDaysGap() -> Int32
    func crawlCutoffDate() -> String
    func knownIdsJson() -> String
}

final class ParamsBridge: NSObject, ScriptParamsBridgeJS {
    private let params: ScriptRunParams

    init(params: ScriptRunParams) {
        self.params = params
    }

    func crawlDaysGap() -> Int32 { Int32(params.crawlDaysGap) }

    func crawlCutoffDate() -> String {
        let cutoff = Calendar.current.date(byAdding: .day, value: -params.crawlDaysGap, to: Date()) ?? Date()
        return Self.dayFormatter.string(from: cutoff)
    }

    func knownIdsJson() -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: params.knownIds),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

/// 日志桥。
@objc protocol ScriptConsoleBridgeJS: JSExport {
    func log(_ message: String)
}

final class ConsoleBridge: NSObject, ScriptConsoleBridgeJS {
    private let onLog: (@Sendable (String) -> Void)?

    init(onLog: (@Sendable (String) -> Void)?) {
        self.onLog = onLog
    }

    func log(_ message: String) {
        onLog?("· \(message)")
    }
}

/// 运行结果上报桥（对齐后端爬虫 progress/partialError 语义）。
@objc protocol ScriptReportBridgeJS: JSExport {
    func stats(_ scanned: Int32, _ skipped: Int32, _ failed: Int32, _ noContent: Int32,
               _ restricted: Int32, _ skippedOld: Int32, _ skippedDuplicate: Int32, _ skippedKnown: Int32)
    func warn(_ message: String)
    func progress(_ scanned: Int32, _ skipped: Int32, _ failed: Int32, _ fraction: Double, _ detail: String)
}

final class ReportBridge: NSObject, ScriptReportBridgeJS {
    private let onLog: (@Sendable (String) -> Void)?
    private let onProgress: (@Sendable (Double, String) -> Void)?
    private(set) var scanned = 0
    private(set) var skipped = 0
    private(set) var failed = 0
    private(set) var noContent = 0
    private(set) var restricted = 0
    private(set) var skippedOld = 0
    private(set) var skippedDuplicate = 0
    private(set) var skippedKnown = 0
    private(set) var warnings: [String] = []

    static let maxWarnings = 20

    init(onLog: (@Sendable (String) -> Void)?, onProgress: (@Sendable (Double, String) -> Void)?) {
        self.onLog = onLog
        self.onProgress = onProgress
    }

    func stats(_ scanned: Int32, _ skipped: Int32, _ failed: Int32, _ noContent: Int32,
               _ restricted: Int32, _ skippedOld: Int32, _ skippedDuplicate: Int32, _ skippedKnown: Int32) {
        self.scanned = max(Int(scanned), 0)
        self.skipped = max(Int(skipped), 0)
        self.failed = max(Int(failed), 0)
        self.noContent = max(Int(noContent), 0)
        self.restricted = max(Int(restricted), 0)
        self.skippedOld = max(Int(skippedOld), 0)
        self.skippedDuplicate = max(Int(skippedDuplicate), 0)
        self.skippedKnown = max(Int(skippedKnown), 0)
    }

    func warn(_ message: String) {
        if warnings.count < Self.maxWarnings {
            warnings.append(String(message.prefix(200)))
        }
        onLog?("· \(message)")
    }

    func progress(_ scanned: Int32, _ skipped: Int32, _ failed: Int32, _ fraction: Double, _ detail: String) {
        onProgress?(min(max(fraction, 0), 1), detail)
        onLog?("· \(detail)（扫描 \(scanned)，跳过 \(skipped)，失败 \(failed)）")
    }
}

// MARK: - 校验用惰性桥（只保证顶层求值不因缺少全局而失败）

final class StubHttpBridge: NSObject, ScriptHttpBridgeJS {
    func get(_ url: String) -> String { "" }
    func post(_ url: String, _ body: String, _ contentType: String) -> String { "" }
}

final class StubHtmlBridge: NSObject, ScriptHtmlBridgeJS {
    func query(_ html: String, _ selector: String) -> String { "[]" }
    func text(_ html: String, _ selector: String) -> String { "" }
    func attr(_ html: String, _ selector: String, _ name: String) -> String { "" }
    func markdown(_ html: String, _ selector: String, _ baseUrl: String) -> String { "" }
}

final class StubUtilBridge: NSObject, ScriptUtilBridgeJS {
    func sha256(_ text: String) -> String { "" }
    func resolveUrl(_ base: String, _ relative: String) -> String { relative }
    func now() -> Double { 0 }
}

final class StubParamsBridge: NSObject, ScriptParamsBridgeJS {
    func crawlDaysGap() -> Int32 { 0 }
    func crawlCutoffDate() -> String { "" }
    func knownIdsJson() -> String { "[]" }
}

final class StubReportBridge: NSObject, ScriptReportBridgeJS {
    func stats(_ scanned: Int32, _ skipped: Int32, _ failed: Int32, _ noContent: Int32,
               _ restricted: Int32, _ skippedOld: Int32, _ skippedDuplicate: Int32, _ skippedKnown: Int32) {}
    func warn(_ message: String) {}
    func progress(_ scanned: Int32, _ skipped: Int32, _ failed: Int32, _ fraction: Double, _ detail: String) {}
}

// MARK: - Swift 异常 → JS 异常

enum JSCBridgeError {
    /// 桥内 Swift 错误转 JS 异常（脚本可 catch，宿主从 context.exception 读取）。
    static func raise(_ error: ScriptError) {
        guard let context = JSContext.current() else { return }
        let constructor = context.objectForKeyedSubscript("Error")
        let exception = constructor?.construct(withArguments: [error.description])
        if let exception {
            context.exception = exception
        }
    }
}
