# data-layer Specification

## Purpose
TBD - created by archiving change ios-foundation-data-layer. Update Purpose after archive.

## Requirements

### Requirement: SQLite schema 与 Android Room v14 对齐
系统 SHALL 在首次启动时创建 8 张表，列、类型、主键、索引、外键与 Android 端
`AppDatabase.kt`（version 14）的实体定义一一对应（语义关键列点名，含 v13/v14 迟到列）：

- `notices`：`id` PK、`sourceId`（可空）、`label`、`title`、`publishedAt`（epoch 毫秒，解析失败 0）、
  `publishedDay`（yyyy-MM-dd）、`detailUrl`、`isPage`、`content`（可空）、
  **`contentVersion`（正文提取格式版本，0=旧格式需重抓）**、`attachments`（JSON 数组）、
  `fetchedAt`、`notified`、`favorite`；
  索引：`publishedAt` / `publishedDay` / `(label, publishedAt)` / `sourceId`。
- `daily_reports`：`day` PK、`status`（running/completed/failed）、`content`、`sourceCount`、
  `error`（可空）、`updatedAt`。
- `notice_sources`：`id` PK、`name`、`version`、`origin`（builtin/sideload）、
  `scriptFile`（可空；侧载脚本落盘文件名，内置为 null）、`domains`/`labels`（JSON 数组）、
  `scheduleMinutes`（默认 360）、`subscribed`、`lastRunAt`（可空）、`lastCount`、`lastError`（可空）。
- `chat_metadata`：`sessionId` PK 自增、`title`、`lastUpdated`。
- `chat_messages`：`messageId` PK 自增、`ownerSessionId`（FK→chat_metadata，索引，级联删除）、
  `text`、`role`（USER/ASSISTANT，String 存储）、
  `attachmentTitles`/`attachmentIds`（附件标题与 id 各一列，JSON 数组）、
  `status`（RUNNING/COMPLETED/FAILED，String 存储，默认 COMPLETED）、
  `runId`（可空）、`delivery`（可空）、`errorCode`（可空）、`timestamp`（毫秒）。
- `chat_tool_calls`：`id` PK 自增、`messageId`（FK→chat_messages，索引，级联删除）、
  `position`、`name`、`summary`、`status`、`code`（可空）、`durationMs`（可空）、
  **`targetId`（可空；工具指向的本地对象 id，read_notice 的资讯 id）**。
- `courses`：`id` PK 自增、`tableId`（FK→table_metadata，索引，级联删除）、`name`、`teacher`、
  `location`、`dayOfWeek`（Int 1-7）、`startPeriod`、`duration`、`color`（ARGB Int64）、
  `weekRule`（JSON 整数集合）、`note`。
- `table_metadata`：`id` PK 自增、`tableName`、`semesterConfig`（JSON：startDate/weeks/visibleDays/periods）、
  `isCurrent`。

Kotlin 复合类型映射约定：`List<String>`/`Set<Int>` → JSON 文本列；`SemesterConfig`/`Period` → JSON 文本列；
时间戳 → 毫秒 epoch `Int64`；课表 `Color` → ARGB `Int64`；枚举 → raw String。

#### Scenario: 首次启动建表
- **WHEN** 应用首次打开数据库
- **THEN** 8 张表与全部索引/外键被创建，schema 版本记为 1

#### Scenario: 删除会话级联清理
- **WHEN** 删除一条 `chat_metadata` 记录
- **THEN** 其名下 `chat_messages` 与关联 `chat_tool_calls` 一并被删除

### Requirement: 数据库以 WAL 池化打开
系统 SHALL 以 `DatabasePool`（WAL 模式）打开数据库，读写并发安全；Agent 检索 SHALL 使用只读连接。

#### Scenario: 并发读写不阻塞
- **WHEN** 一个写入事务进行中
- **THEN** 并发读查询可正常返回（WAL 语义）

#### Scenario: 只读连接拒绝写
- **WHEN** 在只读连接（`db.read`）上执行写操作
- **THEN** 操作失败并抛出错误，连接保持只读

### Requirement: 资讯检索（Agent 对位）
系统 SHALL 提供 `searchNotices`，参数哨兵语义与 Android 一致：
`query`/`label`/`fromDay`/`toDay` 空串 = 不过滤，`sourceId` nil = 不过滤，`favoriteOnly` 0 = 不过滤。
命中条件为 `title LIKE '%q%' OR content LIKE '%q%'`。
标题命中优先排序 SHALL 仅在 `relevance=1` 且 `query` 非空时启用（Agent 检索路径），
其余情况纯时间倒序。
所有排序 SHALL 以 `id DESC` 作稳定排序（tie-break），支持 offset/limit 分页。

#### Scenario: 标题命中优先
- **WHEN** relevance=1 时检索词同时命中 A 的标题与 B 的正文
- **THEN** A 排在 B 之前

#### Scenario: 分页一致
- **WHEN** 相同参数下取 limit 10 offset 0 与 offset 10
- **THEN** 两页结果无重叠且并集等于全量命中（publishedAt 相同的条目靠 id DESC 稳定排序）

### Requirement: 资讯流与收藏
系统 SHALL 提供资讯流查询 `listByLabel`（label 必选、sourceId 可选筛选、
`ORDER BY publishedAt DESC, id DESC`、分页）、收藏标记切换（`favorite` 布尔列，不单独建表）、
通知水位（`notified` 标记）读写、按源计数观察。
系统 SHALL 提供正文补抓判定 `idsWithContentBySource`：
content 非空且 `contentVersion >= 最低版本` 或 `isPage = 0` 的条目视为「已有正文」，
其余条目留给脚本宿主（阶段 2）重抓。
系统 SHALL 提供日报取数 `idsByDay`（某日发布资讯 id，publishedAt 升序）。

#### Scenario: 数据源筛选
- **WHEN** 指定 sourceId 查询资讯流
- **THEN** 仅返回该源的条目，按 publishedAt DESC、id DESC 排序

#### Scenario: 正文补抓判定
- **WHEN** 查询某源「已有正文」的条目 id（最低版本 = 1）
- **THEN** 仅 content 为空/空串或 contentVersion=0 的 isPage 条目被排除；isPage=0 的条目始终视为已有正文

### Requirement: 会话/消息/工具卡持久化
系统 SHALL 提供聊天三层持久化：会话（chat_metadata，lastUpdated 倒序列出）、
消息（chat_messages，含 status=RUNNING/COMPLETED/FAILED、role=USER/ASSISTANT、
附件标题与 id 两列、runId/delivery/errorCode 回写）、
工具调用（chat_tool_calls，含 position 有序、durationMs、targetId）。
会话内消息 SHALL 按 `timestamp ASC, messageId ASC` 排序
（Android 仅 `timestamp ASC`；messageId tie-break 为 iOS 无损增强，避免同毫秒插入乱序）。
工具轨迹随消息落库，重启后可完整还原。

#### Scenario: 工具轨迹还原
- **WHEN** 写入一条 assistant 消息及 2 条工具调用后重新查询
- **THEN** 消息与工具卡按 position 顺序完整返回，targetId 一并还原

#### Scenario: 消息回写
- **WHEN** 一条 RUNNING 消息通过结束回写（text/status/delivery/errorCode）更新后重查
- **THEN** 仅这些字段变化，attachmentIds 等其余字段保持原值

### Requirement: 课表持久化
系统 SHALL 提供多课表（table_metadata + SemesterConfig JSON）与课程（courses，含
weekRule 集合、dayOfWeek、起止节次）的 CRUD，课程归属其 tableId。
切换当前课表 SHALL 为原子操作（先全部置 0 再置目标为 1）。
系统 SHALL 提供清理无课程空课表的能力。

#### Scenario: 删除课表级联
- **WHEN** 删除一个 table_metadata
- **THEN** 该表全部 courses 被级联删除

#### Scenario: 切换当前课表原子性
- **WHEN** 把课表 B 设为当前
- **THEN** isCurrent=1 的记录有且仅有 B

### Requirement: 数据源注册表持久化
系统 SHALL 提供 notice_sources 的 CRUD（含 subscribed 开关、version/origin/scriptFile、
domains/labels JSON 列、scheduleMinutes）与运行状态回写（lastRunAt/lastCount/lastError）。
列表查询排序与 Android 一致：`subscribed DESC, id='seu-jwc' 置顶, origin DESC, name ASC`。

#### Scenario: 订阅开关持久化
- **WHEN** 将某源 subscribed 置为 true 后重查
- **THEN** 该源保持 subscribed=true

#### Scenario: 运行状态回写
- **WHEN** 某源完成一轮运行后回写时间戳/新增条数/错误摘要
- **THEN** 重查时三个字段均为新值

### Requirement: 日报持久化
系统 SHALL 提供 daily_reports 的按日 upsert（day 主键、status=running/completed/failed、
content、sourceCount、error、updatedAt），并提供「不晚于某日的最近一份已完成日报」查询。
upsert SHALL 带防降级守卫：已处于 completed 的记录不被后续写入覆盖。

#### Scenario: 日报状态机
- **WHEN** 同一 day 先写 running 再写 completed
- **THEN** 仅保留一条记录且 status=completed

#### Scenario: 已完成日报不被覆盖
- **WHEN** 同一 day 已是 completed 后再写入 running
- **THEN** 记录保持 completed 与原 content 不变

### Requirement: LLM Key Keychain 存取
系统 SHALL 将 LLM API Key 存入 iOS Keychain（kSecClassGenericPassword），
按 providerId 索引（account = providerId，service 固定），提供 save/load/delete。
空串 SHALL 视为未设置（load 返回 nil）。
Keychain 条目 SHALL 设置 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，
且不得随 iCloud/设备迁移同步（synchronizable = false）——后台任务（阶段 7）在锁屏下可读，
Key 不离开本设备。Key 值 SHALL NOT 出现在任何日志输出中。

#### Scenario: 多 provider 隔离
- **WHEN** 为 providerA、providerB 分别保存不同 Key 后读取
- **THEN** 各自返回各自原文；delete providerA 后 providerB 仍可读

#### Scenario: Key 存取回环
- **WHEN** save 后 load
- **THEN** 返回原文；delete 后 load 返回 nil；保存空串后 load 返回 nil

### Requirement: 用户设置存取
系统 SHALL 提供 UserDefaults 封装的用户设置读写，存储结构与 Android 对齐：

- LLM provider 配置以**单键 JSON** 存取（`LlmProviderConfig`：providerId/protocol/baseUrl/
  model/temperature/maxTokens），默认 providerId=openai、protocol=openai、
  baseUrl=https://api.openai.com/v1、model=gpt-4o-mini、temperature=0.7、maxTokens=2048
  （对位 Android `llm_prefs` 的 `provider_config` 单键）。
- 其余设置逐 key 存储（key 名与 Android DataStore 一致），默认值对齐 Android `UserSettings`：
  freshDays=21、newsCheckIntervalMinutes=60、newsNotificationEnabled=false、
  dailyReportEnabled=false、dailyReportTime="00:10"、crawlDaysGap=200、
  mottoText="笃学尚行"、mottoOnline=true、hitokotoMaxLength=30，及其余全部字段。
- `deletedSourceIds`（用户删除过的内置数据源 id 集合）SHALL 可增删查，
  供数据源同步逻辑防止已删除的内置源复活。

#### Scenario: 默认值
- **WHEN** 未写入任何设置时读取
- **THEN** 各字段返回与 Android 端一致的默认值

#### Scenario: 删除的内置数据源记录
- **WHEN** 记录某内置源 id 为已删除后读取
- **THEN** 该 id 出现在 deletedSourceIds 中；清除该 id 后集合不再包含它

### Requirement: 单元测试覆盖
系统 SHALL 提供 XCTest 单测，覆盖上述全部 Scenario；数据库逻辑测试用内存
`DatabaseQueue`（同一套 Migrations），WAL 并发与只读 Scenario 用临时文件
`DatabasePool`（`:memory:` 无法承载多连接池）；并统一通过
`xcodebuild test -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`。

#### Scenario: 测试套件全绿
- **WHEN** 执行 `xcodebuild test`（iPhone 17 Pro 模拟器目标）
- **THEN** 全部测试通过且无跳过项
