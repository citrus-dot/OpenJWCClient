# Design: ios-foundation-data-layer

## 目录与工程管理

```
Packages/OpenJWCCore/          # SwiftPM 域层包（双平台：iOS 18 / macOS 15）
├── Package.swift              # GRDB 7.11.1；阶段 2 追加 SwiftSoup
├── Sources/OpenJWCCore/
│   ├── Database/
│   │   ├── DatabaseProvider.swift   # DatabasePool 构建、迁移注册（平台中立路径）
│   │   ├── Migrations.swift         # 终态 schema（v1 起步）
│   │   └── DAO/                     # NoticeDao/ChatDao/TimetableDao/SourceDao/DailyReportDao
│   ├── Models/                      # 8 组 struct + 2 聚合 + JSON 列包装
│   ├── LLM/LlmKeyStore.swift        # Keychain 封装（按 providerId）
│   ├── Settings/SettingsStore.swift # UserDefaults 双域（llm_prefs / user_settings）
│   ├── Scripting/                   # 阶段 2：JSC 宿主 + 六桥
│   └── Agent/                       # 阶段 3：AgentLoop + 工具
└── Tests/OpenJWCCoreTests/    # Swift Testing（macOS swift test 驱动）
ios/                           # XcodeGen 占位 app（阶段 4 接线 core，Tahoe 后）
```

- **D7 时序**：Tahoe 升级前域层用 macOS `swift test` 驱动（零模拟器）；部署目标按 **D6 = iOS 18.0 baseline**（core 包 platforms 声明 iOS 18/macOS 15），Liquid Glass 为 UI 层 `#available(iOS 26)` 增强。
- Swift 6 严格并发；DAO/Provider 全部 Sendable。
- **ValueObservation 后移决策**：GRDB 7 `tracking` 的 `-> Self where Reducer == ValueReducers.Fetch<Value>` 约束使标注返回类型 `ValueObservation<[T]>` 不可行；observation API 推迟到 UI 接线阶段按官方模式实现，本阶段 DAO 仅快照（async）查询。

## 依赖

- **GRDB.swift 7.x**（SPM，锁定 `from: "7.11.1"`；当前最新 7.11.1，2026-06 发布——**不存在 8.x**）。
  要求 Swift 6.1+ / Xcode 16.3+，最低 iOS 13（部署目标 26.0 远高于此，无版本压力）。
  GRDB 7 对 Swift 6 strict concurrency 标注完整，`DatabasePool` 为 Sendable。
- 无其他第三方依赖；Keychain/UserDefaults 用系统 API。

## 数据映射策略（Room → GRDB）

| Android 概念 | iOS 对位 | 备注 |
|---|---|---|
| `@Entity` data class | `struct: Codable, FetchableRecord, PersistableRecord` | |
| Room TypeConverter（List/Set→JSON） | 自定义 `DatabaseValueConvertible` / `Codable` 包装列 | 空 JSON 解析失败回退空集合（对齐 Android Converters 的宽容回退） |
| `@PrimaryKey(autoGenerate)` | `grdbAutoIncrementPrimaryKey`（`INTEGER PRIMARY KEY AUTOINCREMENT`） | |
| `@Embedded` + `@Relation`（`ChatSession`/`ChatTurn` 聚合） | 手写组装：先取父记录，再按外键批量取子记录拼装 | GRDB 无自动关系图；不照搬 Room 注解 |
| Room `@Dao` 挂库对象 | `struct XxxDao { let db: DatabasePool }`（方法内 `db.write/read`，async） | |
| Room `Flow<T>` 查询 | GRDB `ValueObservation`（`.publisher` / AsyncSequence） | UI 阶段（4–6）才接 SwiftUI，本阶段先在 DAO 暴露 |
| `@Upsert`（notices/source） | GRDB `upsert()`（`INSERT ... ON CONFLICT DO UPDATE`） | 语义等同：冲突走 UPDATE，不触发级联 |
| `@Insert(onConflict = REPLACE)`（course/table） | **禁止照抄**：GRDB `save()`（先 UPDATE 未命中再 INSERT） | 见下方「REPLACE 级联陷阱」 |
| Room 迁移链 v2→v14 | **不搬运**：`Migrations.swift` 只定义 v1 终态建表（Android 侧历史迁移是给存量用户升级的，iOS 无存量）；后续 schema 变更走 GRDB migrator 新增 v2+，禁止 destructive fallback | |
| `System.currentTimeMillis()` | `Int64` 毫秒 epoch（两端数值语义一致） | |
| `Role`/`MessageStatus` 枚举 | Swift enum + raw String 存储；解码失败回退默认值（USER/COMPLETED） | 对齐 Android Converters 的 try-catch 回退 |
| 课表 `Color` | ARGB `Int64`（两端数值一致；SwiftUI 端再转 `Color`） | |
| `dayOfWeek` | Int 1–7（ISO，两端一致） | |

### REPLACE 级联陷阱（两端语义差异，必须规避）

SQLite 的 `INSERT OR REPLACE` 实现为 DELETE + INSERT：父行被替换时会触发
`ON DELETE CASCADE`，级联清空子行。Android `TableDao.insertTable` 用 `@Insert(REPLACE)`
更新已有课表存在清空其课程的隐患（靠「新增时无子行」侥幸避开）。iOS 端：

- `table_metadata`/`courses` 写入一律用 GRDB `save()`（update-else-insert）或 `upsert()`
  （ON CONFLICT DO UPDATE），**不用** `insert(or: .replace)`；
- 单测锁定：更新已有课表元数据后，其名下课程计数不变。

### 外键

DDL 显式写 `FOREIGN KEY(...) REFERENCES ... ON DELETE CASCADE`；
GRDB 打开每个连接时默认执行 `PRAGMA foreign_keys = ON`，无需手动开启。

## 查询语义对齐

- `searchNotices`：参数哨兵语义照抄 Android（`query`/`label`/`fromDay`/`toDay` 空串、
  `sourceId` nil、`favoriteOnly` 0 = 不过滤）；SQL
  `WHERE (title LIKE ? OR content LIKE ?) [+ sourceId/label/日期]`，
  `ORDER BY (relevance=1 且标题命中 THEN 0 ELSE 1), publishedAt DESC, id DESC`，
  `LIMIT ? OFFSET ?`——标题命中优先是 `relevance` 参数控制的可选行为（Agent 检索路径传 1）；
  `id DESC` 稳定排序是分页一致性的前提，不可省。不用 FTS，理由同 Android（中文分词）。
- 资讯流/收藏/水位/补抓判定、聊天三层、课表、数据源、日报：逐条对照 Android
  `NoticeDao`/`ChatDao`/`CourseDao`/`TableDao`/`SourceDao`/`DailyReportDao` 的查询实现
  （含排序 tie-break、`idsWithContentBySource` 的 contentVersion 判定、
  日报 save 的 `WHERE status <> 'completed'` 防降级守卫、SourceDao 的置顶排序）。
- `chat_messages` 排序在 Android `timestamp ASC` 基础上补 `messageId ASC` tie-break
  （无损增强：同毫秒写入按插入序，两端可见行为一致）。

## Keychain 设计（LlmKeyStore）

- `kSecClassGenericPassword`，`service` 固定（如 `OpenJWC.llm-keys`），`account = providerId`
  ——对位 Android `LlmKeyStore` 的 per-provider 多 Key 结构。
- `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` + `synchronizable = false`：
  后台任务（阶段 7 的通知抓取、日报生成）在锁屏下运行，`WhenUnlocked` 会读不到 Key；
  `ThisDeviceOnly` 保证 Key 不随 iCloud/设备迁移泄漏。这是 iOS 特有决策（Android
  EncryptedSharedPreferences 无此维度）。
- load 时 `takeIf { !$0.isEmpty }`——空串视为未设置（对齐 Android）。
- save 前 `SecItemDelete` 再 `SecItemAdd`（Keychain 无原生 upsert）。
- 日志脱敏：任何调用点不得打印 Key 值；错误只报 OSStatus。

## 设置存储设计（SettingsStore）

- `UserDefaults`，两个命名域对位 Android 两个 DataStore：
  - LLM 配置（`llm_prefs` 对位）：单键 JSON 存 `LlmProviderConfig`
    （providerId/protocol/baseUrl/model/temperature/maxTokens）——**不拆字段**，
    对齐 Android `provider_config` 的整体 JSON 结构，未来加字段零迁移。
  - 用户设置（`user_settings` 对位）：逐 key 存储，key 名与 Android 一致
    （snake_case），默认值逐字段对齐 `UserSettings`（含 motto/hitokoto 系列与
    `crawlDaysGap=200`、`dailyReportTime="00:10"` 等）。
- `deletedSourceIds`：Set<String> 以 JSON 数组存 UserDefaults
  （对位 Android `stringSetPreferencesKey("deleted_source_ids")`）。
- 观察机制：本阶段仅提供快照读写；`AsyncStream` 值观察（KVO/NotificationCenter 桥接）
  留到 UI 阶段实现，接口先在 protocol 里预留。
- iOS 适配注记：`backgroundPath` 在 iOS 存沙盒相对路径（容器绝对路径每次安装会变），
  UI 阶段落地时以 `URL(stringRelativeTo:)` 或容器相对字符串存储。

## 测试策略

- 每个 Requirement 一个测试类。
- 数据库逻辑：in-memory `DatabaseQueue` + 同一套 Migrations（快、隔离）。
- **WAL 并发与只读 Scenario 必须用临时文件 `DatabasePool`**：
  `:memory:` 无法承载 DatabasePool 的多连接语义（每连接独立内存库），测不了并发读写——
  用 `FileManager.temporaryDirectory` 下的唯一路径建池，测试后清理。
- 级联删除/回环/排序/分页/守卫（日报防降级、课表 REPLACE 语义）Scenario 逐一对应测试方法。
- Keychain 测试用真 Keychain（模拟器沙盒内可读写，测试后清理）。
- 命令：`cd Packages/OpenJWCCore && swift test`（macOS，阶段 1–3 唯一验收通道）。

## 风险与回退

- GRDB 7 的 Swift 6 并发标注：`DatabasePool` Sendable，DAO 方法 async 化即可，无历史包袱。
- XcodeGen 版本差异导致生成失败：锁定 brew 版本，`project.yml` 是唯一真源。
- GRDB `save()` 依赖主键存在性判断，与 Room `REPLACE` 行为差异已用单测锁定（更新课表不清课程）。
- 若 Keychain 在 CI/模拟器异常：回退方案为 UserDefaults + 开发期警告（Key 不落盘的硬要求让位于可测试性，记录为已知妥协，上线前必须回到 Keychain）。
