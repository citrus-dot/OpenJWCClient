# Tasks: ios-foundation-data-layer

### 1. 工程脚手架
- [x] 1.1 brew 安装 XcodeGen；建 `ios/project.yml`（target OpenJWC + OpenJWCTests，iOS 26.0，Swift 6，SPM 引 GRDB `from: "7.11.1"`）
- [x] 1.2 建 `ios/OpenJWC/App/OpenJWCApp.swift` 占位入口 + `.gitignore`（xcodeproj/DerivedData）
- [x] 1.3 `xcodegen generate` 生成工程并 `xcodebuild build` 通过
- 对应 Scenario：首次启动建表（前置）

### 2. GRDB 集成与 schema
- [x] 2.1 `DatabaseProvider`（DatabasePool + WAL + 迁移注册）
- [x] 2.2 `Migrations.swift`：8 张表终态 DDL（列/索引/外键级联），对齐 Android `AppDatabase.kt` v14 逐字段核对——**点名易漏列：`notices.contentVersion`、`chat_tool_calls.targetId`、`chat_messages.attachmentTitles/attachmentIds/runId/delivery/errorCode`、`notice_sources.version/origin/scriptFile/scheduleMinutes`**
- [x] 2.3 `Models/`：8 组 struct + `ChatSession`/`ChatTurn` 聚合（手写组装）+ 复合类型映射（JSON 列解析失败回退空集合、毫秒时间戳、ARGB Color、枚举 String + 回退默认值）
- 对应 Requirement：schema 对齐、WAL 池化

### 3. DAO 层
- [x] 3.1 `NoticeDao`：流查询（`publishedAt DESC, id DESC` tie-break/筛选/分页）、收藏切换、通知水位、`searchNotices`（哨兵参数 + relevance 开关 + 标题优先 + tie-break + 分页）、`idsWithContentBySource`（contentVersion 补抓判定）、`idsByDay`、`labelCounts`/`distinctLabels`/`minDay`/`maxDay`、按源计数
- [x] 3.2 `ChatDao`：会话 CRUD（lastUpdated 倒序）+ 消息（status/role/附件两列/runId 回写/结束回写、`timestamp ASC, messageId ASC` 排序）+ 工具卡（position 有序、completeToolCall、targetId）；删除会话级联
- [x] 3.3 `CourseDao` + `TableDao`：多课表 + 课程 CRUD（SemesterConfig JSON 列）；**写入用 `save()`/`upsert()`，禁用 `insert(or: .replace)`（REPLACE 级联陷阱）**；删表级联删课；切换当前课表原子事务；`deleteEmptyTables`
- [x] 3.4 `SourceDao`：注册表 CRUD（subscribed/version/origin/scriptFile/scheduleMinutes）+ 运行状态回写 + 置顶排序（`subscribed DESC, seu-jwc 置顶, origin DESC, name ASC`）
- [x] 3.5 `DailyReportDao`：按日 upsert（**`WHERE status <> 'completed'` 防降级守卫**）+ `latestCompleted(before)`
- 对应 Requirement：检索、资讯流、聊天、课表、数据源、日报

### 4. Keychain 与设置
- [x] 4.1 `LlmKeyStore`：Keychain save/load/delete（account=providerId、`AfterFirstUnlockThisDeviceOnly`、非同步、空串视为 nil、save 前 delete+add），日志脱敏自查
- [x] 4.2 `SettingsStore`：UserDefaults——LLM 配置单键 JSON（`LlmProviderConfig` 全字段）+ UserSettings 逐 key（key 名与默认值对齐 Android 全字段）+ `deletedSourceIds` 集合读写；预留 AsyncStream 观察接口
- 对应 Requirement：LLM Key、用户设置

### 5. 测试与验收
- [x] 5.1 `OpenJWCTests`：每 Requirement ≥1 测试，覆盖 spec 全部 Scenario——in-memory `DatabaseQueue` 测逻辑；**WAL 并发/只读拒写用临时文件 `DatabasePool`**；含日报防降级、分页 tie-break（同 publishedAt 不同 id）、课表更新不清课程、Keychain 多 provider 隔离
- [x] 5.2 `swift test`（macOS，D7 时序下域层唯一验收通道）全绿：**23/23 通过**
- [ ] 5.3 `openspec validate ios-foundation-data-layer` 通过后申请归档
- 对应 Requirement：单元测试覆盖
