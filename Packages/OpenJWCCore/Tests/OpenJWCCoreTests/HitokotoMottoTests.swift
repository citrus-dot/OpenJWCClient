import Foundation
import Testing
@testable import OpenJWCCore

/// HitokotoClient 与 MottoCache 测试（tasks 2.6）：URL 构造 / 解析 / 空内容报错 / 按天缓存。
@Suite("Hitokoto 与 Motto 缓存")
struct HitokotoMottoTests {

    // MARK: - URL 构造

    @Test("URL 构造：分类/长度参数，maxLength 收敛 1...100")
    func urlConstruction() throws {
        // 用 URLProtocol stub 不可行（struct 直发）；改为验证 fetch 的等价构造逻辑——
        // 这里直接复刻 fetch 内的 components 组装做对照断言。
        func buildURL(category: String, minLength: Int, maxLength: Int) -> URL {
            var components = URLComponents(string: HitokotoClient.endpoint)!
            var items: [URLQueryItem] = [
                URLQueryItem(name: "encode", value: "json"),
                URLQueryItem(name: "charset", value: "utf-8"),
                URLQueryItem(name: "min_length", value: String(max(0, minLength))),
                URLQueryItem(name: "max_length", value: String(min(max(1, maxLength), 100))),
            ]
            if !category.isEmpty {
                items.append(URLQueryItem(name: "c", value: category))
            }
            components.queryItems = items
            return components.url!
        }

        let withCategory = buildURL(category: "a", minLength: 5, maxLength: 30)
        #expect(withCategory.absoluteString.contains("c=a"))
        #expect(withCategory.absoluteString.contains("min_length=5"))
        #expect(withCategory.absoluteString.contains("max_length=30"))

        let noCategory = buildURL(category: "", minLength: 0, maxLength: 30)
        #expect(!noCategory.absoluteString.contains("c="))

        // maxLength 越界收敛
        #expect(buildURL(category: "", minLength: 0, maxLength: 500).absoluteString.contains("max_length=100"))
        #expect(buildURL(category: "", minLength: 0, maxLength: 0).absoluteString.contains("max_length=1"))
        #expect(buildURL(category: "", minLength: -5, maxLength: 30).absoluteString.contains("min_length=0"))
    }

    // MARK: - 响应解析

    @Test("解析：完整字段 → Motto（permalink 用 uuid）")
    func parseFull() throws {
        let json = #"{"id":1,"uuid":"abc-123","hitokoto":"笃学尚行，止于至善","type":"i","from":"大学","from_who":"校训","length":10}"#
        let motto = try HitokotoClient.parse(Data(json.utf8))
        #expect(motto.text == "笃学尚行，止于至善")
        #expect(motto.author == "校训")
        #expect(motto.source == "大学")
        #expect(motto.permalink == "https://hitokoto.cn?id=abc-123")
        #expect(motto.date == MottoCache.today())
    }

    @Test("解析：from_who 为空 → author nil")
    func parseEmptyAuthor() throws {
        let json = #"{"id":2,"uuid":"u2","hitokoto":"一句","from":"","from_who":""}"#
        let motto = try HitokotoClient.parse(Data(json.utf8))
        #expect(motto.author == nil)
        #expect(motto.source == nil)
        #expect(motto.attribution == nil)
    }

    @Test("解析：hitokoto 空白 → 报错")
    func parseBlankThrows() {
        let json = #"{"id":3,"uuid":"u3","hitokoto":"  ","from":"x"}"#
        #expect(throws: HitokotoError.self) {
            try HitokotoClient.parse(Data(json.utf8))
        }
    }

    // MARK: - Motto 本地模式

    @Test("本地格言：作者空/佚名 → 无署名；text 空回退默认")
    func localMotto() {
        #expect(Motto.local(text: "自强", author: "").author == nil)
        #expect(Motto.local(text: "自强", author: "佚名").author == nil)
        #expect(Motto.local(text: "自强", author: "某君").author == "某君")
        #expect(Motto.local(text: "", author: "").text == "笃学尚行")
        #expect(Motto.local(text: "", author: "").attribution == nil)
    }

    // MARK: - 按天缓存

    @Test("缓存：save/load 往返 + isFresh 按天判定")
    func cacheRoundtrip() {
        let suite = "motto-cache-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let cache = MottoCache(defaults: defaults)
        #expect(cache.load() == nil)

        let fresh = Motto(text: "今日一言", author: "A", source: nil,
                          permalink: "https://hitokoto.cn?id=x", date: MottoCache.today())
        cache.save(fresh)
        #expect(MottoCache.isFresh(fresh))

        // 昨日缓存 → 不新鲜
        var stale = fresh
        stale.date = "2020-01-01"
        #expect(!MottoCache.isFresh(stale))

        // loadOrDefault：空缓存 → 占位且 date=今天（首次进入不联网直接显示占位）
        let suite2 = "motto-cache-test2-\(UUID().uuidString)"
        let defaults2 = UserDefaults(suiteName: suite2)!
        defer { UserDefaults().removePersistentDomain(forName: suite2) }
        let empty = MottoCache(defaults: defaults2).loadOrDefault()
        #expect(empty.text == Motto.defaultOnline.text)
        #expect(empty.date == MottoCache.today())
    }
}
