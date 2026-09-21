import Foundation
import Testing
@testable import OpenJWCCore

/// 阶段 2：脚本清单 / HtmlToMarkdown / JSC 宿主（离线部分）
@Suite("Scripting")
struct ScriptingTests {
    @Test("Manifest 解析：@id/@schedule 下限/列表字段")
    func manifestParsing() throws {
        let script = """
        // @id seu-jwc
        // @name 东南大学教务处
        // @version 1.2.0
        // @schedule 10
        // @domains jwc.seu.edu.cn
        // @labels 最新动态,教务信息 | 学籍管理

        function fetchNotices() {}
        """
        let manifest = ScriptManifestParser.parse(script)
        #expect(manifest?.id == "seu-jwc")
        #expect(manifest?.name == "东南大学教务处")
        #expect(manifest?.version == "1.2.0")
        #expect(manifest?.scheduleMinutes == 15) // 下限钳制
        #expect(manifest?.labels.count == 3)
        #expect(ScriptManifestParser.parse("// no id here") == nil)
    }

    @Test("HtmlToMarkdown：标题/列表/表格/链接/图标丢弃")
    func htmlToMarkdown() {
        let md = HtmlToMarkdown.convert(
            "<h2>通知</h2><p>详见 <a href='/x.htm'>公告</a> 与 <a href='/icon_a.png'>图标</a></p>" +
            "<ul><li>一</li><li>二</li></ul>" +
            "<table><tr><th>项</th><th>值</th></tr><tr><td>A</td><td>B</td></tr></table>",
            baseUrl: "https://jwc.seu.edu.cn/"
        )
        #expect(md.contains("## 通知"))
        #expect(md.contains("[公告](https://jwc.seu.edu.cn/x.htm)"))
        #expect(!md.contains("icon_"))           // 模板图标链接被丢弃
        #expect(md.contains("- 一\n- 二"))
        #expect(md.contains("| 项 | 值 |"))
        #expect(md.contains("| A | B |"))
    }

    @Test("JSC 宿主：六桥端到端（离线）")
    func hostEndToEnd() async throws {
        let host = JavaScriptHost()
        let sandbox = ScriptSandbox(allowedDomains: [], timeoutMs: 10_000, maxHttpCalls: 5)
        let logs = LogCollector()
        let outcome = try await host.run(
            script: """
            // @id test-source
            function fetchNotices() {
              const rows = JSON.parse(dom.query("<ul><li class='n'><a href='/a.htm'>标题A</a></li>" +
                  "<li class='n'><a href='/b.htm'>标题B</a></li></ul>", "li.n a"));
              report.stats(rows.length, 0, 0, 0, 0, 0, 0, 0);
              report.warn("测试警告");
              console.log("hello bridge");
              return JSON.stringify(rows.map(function (r) {
                return {
                  id: util.sha256(r.attrs.href),
                  label: "测试",
                  title: r.text,
                  date: "2026-09-20",
                  detail_url: util.resolveUrl("https://example.com/", r.attrs.href),
                  is_page: true,
                };
              }));
            }
            """,
            sandbox: sandbox,
            params: ScriptRunParams(crawlDaysGap: 30),
            onLog: { logs.append($0) }
        )
        #expect(outcome.notices.count == 2)
        #expect(outcome.notices[0].title == "标题A")
        #expect(outcome.notices[0].detailUrl == "https://example.com/a.htm")
        #expect(outcome.notices[0].id.count == 64) // sha256 hex
        #expect(outcome.scanned == 2)
        #expect(outcome.warnings == ["测试警告"])
        #expect(logs.snapshot().contains("· hello bridge"))
    }

    @Test("JSC 沙箱：域名白名单拦截")
    func sandboxBlocks() async throws {
        let host = JavaScriptHost()
        let sandbox = ScriptSandbox(allowedDomains: ["example.com"], timeoutMs: 10_000)
        do {
            _ = try await host.run(
                script: """
            function fetchNotices() {
              http.get("https://evil.example.org/");
              return JSON.stringify([]);
            }
            """,
                sandbox: sandbox
            )
            Issue.record("应触发沙箱异常")
        } catch let error as ScriptError {
            guard case .execution = error else {
                Issue.record("应为 execution 错误（JS 异常包装）：\(error)")
                return
            }
        }
    }

    @Test("JSC 校验：无 fetchNotices 报错")
    func validateRejects() {
        let host = JavaScriptHost()
        #expect(host.validate(script: "// @id x\nvar a = 1;") != nil)
        #expect(host.validate(script: "// @id x\nfunction fetchNotices() { return JSON.stringify([]); }") == nil)
    }
}

/// @Sendable 闭包可捕获的线程安全日志收集器。
final class LogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ item: String) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }
    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
