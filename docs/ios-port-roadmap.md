# OpenJWC iOS 移植：交接文档与可查验路线（v2）

> **文档用途**：`/Users/orange/OpenJWC_4ios` 工作区 iOS 移植项目的完整交接与路线规划，供任何新会话（agent 切换）直接接手。本文档自包含：决策链、用户原话存档、已完成工作及**逐项查验命令**、后续路线、风险清单。进度真源 = 本文档 + 项目记忆（ZCode memory / ai-memory）。
>
> **最近更新**：2026-09-22（阶段 6 课表实施中：6a core 三件套 + 周视图网格 + 拖拽全链路完成，98/19 测试绿，模拟器渲染验证通过；待用户拖拽手验 → 6b 编辑器/表管理/导入导出/Agent 接线。见 §5 阶段 6 小节）　**前版**：2026-09-22（阶段 5 聊天+日报+Me 完成归档）

---

## 1. 项目背景速览

- **OpenJWC**：东南大学教务资讯助手。原架构 = Android 客户端 + 自建 Go 服务端；当前分支 `feat/on-device-ai` 已完成**去云端改造**（本地 QuickJS 脚本抓资讯 + BYOK API Key 直连 LLM + 本地 Agent 循环）。远端 `OpenJWC/OpenJWCClient`，仅 `master` 与 `feat/on-device-ai` 两分支，作者 SakiMidare。
- **本工作区** = `feat/on-device-ai` 分支克隆（HEAD `92ae0d5`，2026-09-17）+ 新增的 iOS 移植产出（`Packages/`、`openspec/`、`ios/` 占位）。
- Android 代码规模：204 个 Kotlin 文件 / 28721 行。iOS 域层包（阶段 1–3 产出）：**20 个 Swift 文件 / 4581 行 + 8 个测试文件**。
- ⚠️ **Android 文档滞后于代码**：README 架构图/特性列表仍是服务端时代；PLAN.md 的 P1 工具清单、Room 版本号（实际 v14 非 v11）均落后。**理解 Android 端以代码为准**。
- Android 端仍在活跃开发，iOS 端接受 feature lag，以 PLAN.md + 代码为共享功能真源。

**组织全景（2026-09-21 调研，8 个公开仓库）**：OpenJWCClient（Android 客户端，本工作区真源）｜openjwc_webapi_golang（Go 单二进制新后端，openapi.yaml v1/v2 共 17 端点，云端版演进线）｜OpenJWC-webapi（Python 旧后端 RAG/语义搜索）｜JwcCrawler（Rust 爬虫）｜OpenJWC-Server（Docker 编排）｜openjwc-qqbot（QQ 推送机器人）｜OpenJWC-web-frontend（React 管理面板）｜.github（org profile）。**注意**：组织 README 链接的 API 文档等 5 篇均不存在；PLAN.md 仅 feat 分支有——一切以代码 + openapi.yaml 为准。**无设计资产仓库**，图标等资源需从客户端 `res/` 提取（MIT）。**iOS 端按 D10 只复刻 on-device 路线**，上述服务端仓库仅作行为对照参考。

**feat 分支功能全集清单**（iOS「功能不缺失」对照口径）：本地 Agent 工具循环（11 工具/引用通知块/工具卡深链）、QuickJS 宿主 + **39 个内置学院脚本**（默认仅订阅教务处）、本地语料 + 离线缓存 + 来源筛选 + 收藏 + 图片查看 + Markdown 详情、本地日报生成、通知深链、**motto 格言（本地编辑器 + hitokoto.cn 在线一言，每日 1 次缓存）**、课程表（拖拽调课/课程提醒/小组件）、主题动画级别、LLM/格言/来源编辑器设置、README 完整用户协议呈现。

## 2. 决策链（全部已拍板，按时间序）

| # | 决策 | 结论 | 日期 | 备注 |
|---|---|---|---|---|
| D1 | 移植方案 | **b：SwiftUI 原生重写**（非 KMP/CMP 共享） | 2026-09-19 | 域层逻辑直译 Swift，UI 全新 SwiftUI |
| D2 | 持久化 | **GRDB**（**7.11.1**，远端实测最新 tag，8.x 不存在；最低 iOS 13） | 2026-09-19 | 淘汰 SwiftData（内存/门槛差）、SQLite.swift（停维护）。早期「8.7.0」为抓取误报，已实测修正 |
| D3 | 开发环境 | **方案 B**：Xcode 26.3 + iOS 26.3.1 模拟器（无真机依赖） | 2026-09-19 | xip 手动下载（2.1G Apple silicon 版），与旧 Xcode 同方式 |
| D4 | 旧 Xcode 处置 | 装 26.3 验证后卸载 16.4 | 2026-09-19 | 已执行 |
| D5 | 发布定位 | **免费 Apple ID 路线**：无 $99/年账号，不做 App Store/TestFlight，未来侧载分发 | 2026-09-19 | |
| D6 | 最低部署目标 | **iOS 18.0 baseline + `if #available(iOS 26.0, *)` Liquid Glass 增强**（方案 b'） | 2026-09-20 | core 包 platforms 声明 iOS 18/macOS 15 |
| D7 | 时序 | **升 Tahoe 前：只做域层（阶段 1–3，macOS 单测驱动，零模拟器）；Tahoe 后：UI 阶段（4–8，My Mac 原生调试）** | 2026-09-20 | ✅ 阶段 1–3 已全部完成 |
| D8 | 腾盘方案 | **已执行**：删除 iOS 26.3.1 模拟器 runtime（+16G，2026-09-20 用户确认后完成） | 2026-09-20 | 模拟器设备定义保留（无害）；Tahoe 后 UI 走 Mac 原生调试 |
| D9 | Xcode 26.3 → 26.4+ 升级与否 | **已执行：升 Xcode 26.6 (17F113)**（26 系列终态稳定版），40/10 测试基线复验通过，xip 已清理 | 2026-09-21 | 选型对比存档见 §10 |
| D10 | 功能对照基准 | **纯 on-device**：以 `feat/on-device-ai` 分支为功能全集（= master 全部 + 本地 AI 增强，ahead 1/behind 0）。投稿/设备绑定/连服务器为云端版历史功能，Android 作者已裁剪，iOS 同步裁剪并声明；域层 Repository 协议天然预留未来云端扩展（如需则另立 OpenSpec 案） | 2026-09-21 | 组织全景见 §1；云端版=Go 后端 openapi.yaml v1/v2 17 端点 |

**背景推论**：Android 作者选型已向 CMP 生态靠（miuix/MaterialKolor/Coil3 均为 KMP 库），但 Nironta 拍板原生重写；目录名 `OpenJWC_4ios` 印证 iOS 化是既定方向。

## 3. 用户原话存档（逐字，勿转述）

> 采用b方案，并尽量使用ios原生组件，采用ios最新设计风格、规范。
> 再完善一下调研结果和方向规划。

> 决策按GRDB。再查询一下有没有更节省内存、更低系统版本的实现方式，并列出优劣势

> 我的意思是能否让方案节省我的mac存储空间，并降低mac系统版本要求

> 实施B方案，注意查看现在xcode的安装方式，照这样按省存储方式安装，缺失信息直接询问我。
> 上架定位选择更廉价的方案。

（AskUserQuestion 拍板 2026-09-19：下载渠道 =「直接手动 xip 26.3」；Xcode 16.4 处置 =「装好 26.3 验证后卸载」；发布定位 =「免费 Apple ID 路线」）

> 已下载完毕，目录如上。可以开始工作
> （文件：/Users/orange/Downloads/Xcode_26.3_Apple_silicon.xip）

> 已返回Install Succeeded 继续进行

> 开始

> 已在workbuddy上对方案进行优化，可以继续推进

> 仔细检查任务完成情况，梳理路线整理为可查验的md文档，供切换agent

**2026-09-19/20 另一会话（OpenJWC4ios）关于模拟器卡顿与 Tahoe 的关键原话**：

> 为什么模拟器使用起来非常卡顿？有没有解决方案？
> 我注意到我的mac上appstore等来源可以直接安装ios端的软件，使用起来非常流畅，是否是有官方的兼容？能否解决这个卡顿问题？
> 若执行c计划，是否对大多数版本的ios设备都支持，仅丢失最新ui？
> 如果我的mac更新到Tahoe，是否能原生跑测试app，解决流畅性问题？
> 那是否可以等我先升级Tahoe再进行开发，这样不需要用到模拟器

## 4. 本机环境现状（2026-09-21 实测）

| 项 | 状态 | 查验命令 |
|---|---|---|
| 机型 / 芯片 / 内存 | MacBook Air / Apple M4 / **16G** | `sysctl hw.model` |
| macOS | **26.6.2 (Tahoe) 已升级**（2026-09-21 核验；阶段 4 前置条件已满足，UI 走 My Mac 原生调试） | `sw_vers` |
| Xcode | **26.6 (17F113)** 已装（2026-09-21 由 26.3 升级，同路径覆盖），Swift 6.3 / iOS 26.5 SDK | `xcodebuild -version` |
| iOS 模拟器 runtime | **已删除**（D8），Disk Images 0 | `xcrun simctl runtime list` |
| 磁盘 | 可用 **62G**（2026-09-21 实测，Tahoe 安装后反而宽裕） | `df -g /` |
| 工具 | xcodegen 2.46.0、aria2 1.37.0（brew）；JDK17（Android 端用） | `xcodegen --version` |
| 免密 sudo | **不可用**——需 root 的 Xcode 操作要请用户手动跑命令 | `sudo -n true` |
| 发布签名 | 免费 Apple ID（7 天签名/侧载） | — |

**环境坑（已踩过）**：
1. macOS 文件系统大小写不敏感，`/tmp` 产物曾撞名；2. 新旧 Xcode 同路径安装时 `xcode-select` 天然生效无需 sudo；3. Xcode 只能从 developer.apple.com/download/all 下 xip（App Store 渠道 26.4+ 要求 Tahoe 装不上）；4. 模拟器卡顿解法：Release 配置跑 UI（最大头）> 减弱动态效果 > 单设备 shutdown；日常 UI 优先 SwiftUI Preview；5. WebSearch/WebFetch 可能撞并发/配额限制，可用 mcp webReader 中转；6. **async 上下文禁用 DispatchSemaphore.wait**（Swift 6），Swift Testing 并行下信号量桥接会死锁（协作池占满互等）——测试直接 async；7. **Xcode 大版本升级后首次命令行构建**需 `xcodebuild -runFirstLaunch` 补组件 + `-downloadPlatform iOS` 重下平台资产（26.6 首次构建即遇；`-downloadPlatform` 会自动连带装 Simulator runtime，勿误跑 `-downloadAllPlatforms`——曾误下 watchOS 3.7G 已删）；8. **NSLock/OSAllocatedUnfairLock 在 async 上下文**：Swift 6 禁止 async 函数体直接 lock()，且 OSAllocatedUnfairLock 要求 State: Sendable——跨域传非 Sendable 值（如 UNNotificationResponse）应先提取 Sendable 字段（DeepLink）再走 AsyncStream 桥；9. **MarkdownUI 2.4 实际 API**：`Markdown(_ content:)` 无主题尾闭包（用 `.markdownTheme()`）、主题预设是 `.basic/.gitHub/.docC`（无 gitbook）、`ImageProvider` 协议方法为 `makeImage(url: URL?)`、TextStyle 用 `ForegroundColor` 非 ForegroundStyle；10. **shell 管道 tail 会缓冲 swift test 输出**到进程结束——长跑测试想看进度须输出到文件后轮询。

## 5. 已完成工作（阶段 0–3）与查验命令

### 阶段 0 — 环境搭建 ✅
Xcode 26.3 + iOS 26.3.1 runtime + 模拟器全家桶（iPhone 17 系列/iPad 全系），SwiftUI 冒烟 App（swiftc 直编 → install → launch）通过。

### 阶段 1 — 数据层 ✅（2026-09-20）
OpenSpec change `ios-foundation-data-layer` 已归档（`openspec/changes/archive/2026-09-20-ios-foundation-data-layer/`，四件套内含 schema 对照与设计细节）。

### 阶段 2 — 脚本宿主 ✅
**真实脚本验收通过**：Android 仓库同一份 `.js` 资产在 JSC 上零修改跑通 seu-jwc / seu-cs / seu-xsxy 三站真实抓取（failed=0、sha256 id、正文 Markdown、正文暂缺告警上报均与 Android 行为一致）。

### 阶段 3 — LLM + Agent ✅（含真实 Key 联测，2026-09-20 全部完成）
Android 端 `AgentLoopTest` 4 用例复刻通过。**真实 Key 联测通过**（`LLMKeyAcceptanceTests`）：百炼 OpenAI 兼容端点 + deepseek-v4.1-flash，JSC 真实抓取灌语料 → AgentLoop 多轮 search_notices/read_notice 工具调用 → SSE 流式 281 delta 逐字输出 → 终答带 Markdown 表格/链接/基于当前日期的建议，事件流完整闭合（63.6s）。Key 从 `~/.openjwc-llm-key` 读取（不入仓库）。

### 总验收（新会话必跑）

```bash
cd /Users/orange/OpenJWC_4ios/Packages/OpenJWCCore
swift test 2>&1 | grep "Test run with"
# 期望：✔ Test run with 40 tests in 10 suites passed
# 注意：ScriptAcceptanceTests 依赖外网（seu.edu.cn）、LLMKeyAcceptanceTests 依赖
# 外网+真实 Key（~/.openjwc-llm-key）；离线环境这两个 suite 失败属正常，
# 此时基线为 37 tests / 8 suites。
```

### 产出物清单（`Packages/OpenJWCCore`，20 文件 4581 行）

| 目录 | 文件 | 内容 |
|---|---|---|
| `Database/` | `DatabaseProvider.swift` | WAL 池化 + 迁移注册（平台中立路径：iOS Documents / macOS App Support） |
| | `Migrations.swift` | Room v14 终态 8 表 DDL（列/索引/外键级联逐字段对齐） |
| | `DAO/NoticeDao.swift` | 资讯流/收藏/水位/`searchNotices`（哨兵参数+relevance+`id DESC` tie-break）/补抓判定 |
| | `DAO/ChatDao.swift` | 会话/消息/工具卡三层（`timestamp ASC, messageId ASC` 排序增强） |
| | `DAO/TimetableDao.swift` | 课表+课程（**禁用 REPLACE**，一律 `ON CONFLICT DO UPDATE`，单测锁定） |
| | `DAO/SourceDao.swift` | 数据源注册表（置顶排序）+ `DailyReportDao`（**防降级守卫**） |
| `Models/` | `Chat.swift` `ColumnTypes.swift` `SourceAndReport.swift` `Timetable.swift` | 8 组 record + `JSONStringList`/`JSONIntSet` 包装（宽容解码）+ `SemesterConfig` |
| `Scripting/` | `ScriptTypes.swift` | Manifest 解析 / ScriptNotice / Outcome / Sandbox（域白名单+计数） |
| | `JavaScriptHost.swift` | JSC 宿主 + 六桥 + task-group 竞速超时（worker 跑完即弃） |
| | `HtmlToMarkdown.swift` | 逐行直译（icon_ 丢弃、紧贴规则、表格拍平） |
| `LLM/` | `LlmClient.swift` | OpenAI 兼容 SSE（`URLSession.bytes.lines`）+ tool_calls 增量 + 10 预设 |
| | `LlmKeyStore.swift` | Keychain per-provider（`AfterFirstUnlockThisDeviceOnly`、非同步） |
| `Settings/` | `SettingsStore.swift` | UserDefaults 双域（`llm_prefs`/`user_settings`）+ `deletedSourceIds` |
| `Agent/` | `AgentTypes.swift` | ToolSpec/Request/Message/Event/Failure/Budget（预算硬编码对齐） |
| | `Corpus.swift` | `NoticeCorpus`/`TimetableSource`/`DailyReportSource` 协议 + GRDB 默认实现 |
| | `AgentTools.swift` | **11 工具全量直译**（spec/summarize/targetId/execute） |
| | `AgentLoop.swift` | 预算循环/收束指令/禁用工具终答/引用资讯块/UTF-8 截断 |
| | `PromptTemplates.swift` | 系统提示词/工具说明/元数据/日报/收束指令（逐字对齐） |

其余产出：`ios/`（XcodeGen 占位 app：`project.yml` + `OpenJWCApp.swift`，阶段 4 接线用）、`openspec/`（含归档 change）。

**工作区 git 状态（2026-09-21 更新）**：iOS 产出已提交并推送至用户 fork——远端 `origin` = `citrus-dot/OpenJWCClient`（用户 fork），`upstream` = `OpenJWC/OpenJWCClient`（原仓库，Android 活跃开发真源，拉更新用）。提交链 `92ae0d5 → c813e61 (chore gitignore) → 657eaa3 (feat OpenJWCCore 包) → af7f4ad (feat app 脚手架/openspec/roadmap)`，已推送 `feat/on-device-ai` 并建立跟踪。`.gitignore` 覆盖：xcodeproj 生成物、.build、.mimosa、.workbuddy、.trae、.agents。提交者身份已按用户要求统一为 GitHub 账号 **citrus-dot**（noreply 邮箱，`git config --global` 已设置，历史提交已 reset-author 重写并 force-push）。

### 阶段 4 — 资讯 UI ✅（2026-09-21 实施完成，剩 9.3 用户手验）

**OpenSpec change `ios-news-ui`**（proposal/specs/design/tasks 四件套在 `openspec/changes/ios-news-ui/`，实施前已按 Android 真源修正两处契约：播种对已删内置源是「装回且默认不订阅并清删除记录」而非「跳过」；抓取失败也回写 lastRunAt+lastError）。`openspec validate` 通过；tasks 26/27 已勾（仅 9.3 手验待用户）。

**产出**：
- core 新增 `NewsCrawl/`：`SourceRegistry.syncBuiltIns(scriptDirectory:)`（幂等播种，返回 SyncResult）+ `NewsCrawlService`（actor：`AsyncStream<CrawlEvent>` 逐源编排、防重入、取消传播、收藏/水位保留、contentVersion=1 补抓判定、buildWarning/summarize 逐字对齐 Android）。
- core public 化最小集：`NoticeRecord`/`NoticeSourceRecord`（全字段 public + 显式 init，Sendable）、`JSONStringList`、`NoticeDao`/`SourceDao` 资讯路径方法 + 新增静态同步查询 `favoritesSync/totalCountSync/subscribedSync`（ValueObservation.tracking 用，D-2 链式模式不标返回类型）。
- app 全量重建（`ios/OpenJWC/`）：`AppEnvironment`（@MainActor 组合根 + bootstrap 播种）、`AppRouter`（DeepLink 路由）、`AppShellView`（五 tab，iOS 26 `tabBarMinimizeBehavior` 就地采用）、News 全套（NewsListView 栏目 tab + 自适应 1/2/3 列网格 + 倒数第 2 项预载 + 下拉刷新；NewsCardView fresh 高亮；SourceFilterSheet；FavoriteListView；NewsDetailView MarkdownUI + ScrollPosition 滚动恢复 + 附件/浏览器外链；ImageViewer 缩放/分享/重试；CrawlProgressPanel 进度/日志/取消；ReactiveStore 三观察；NewsStore 分页状态机；CrawlCoordinator 事件→UI）。
- 39 个脚本资产以 folder reference 打包进 app（`ios/OpenJWC/Resources/Sources/`）。

**自动化验收（已过）**：
```bash
cd /Users/orange/OpenJWC_4ios/Packages/OpenJWCCore
swift test --filter AllSourcesSmoke   # 39 源真实抓取：0 致命失败、累计 2787 条、35 警告源均为附件/PDF 正文暂缺类（Android 同源）~25min
swift test                            # 全量 51 tests / 13 suites（基线 40 + 播种 3 + 编排 6 + 冒烟 1 + 1 抽验）需外网
cd /Users/orange/OpenJWC_4ios/ios && xcodegen generate
xcodebuild -scheme OpenJWC -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO build
# 模拟器已实测：App 启动 → 落资讯 tab → 39 源播种（DB 验证 39 条、仅 seu-jwc subscribed）→ 栏目/空态渲染正常
```

**待办（9.3 用户手验）**：下拉刷新真实抓取（模拟器无法自动化手势）、源筛选、收藏/清空、详情 Markdown/图片/附件、调试铃铛（#if DEBUG）三连通知验深链（含无效 id 降级）。本机无签名身份（免费 Apple ID 未登录 Xcode），Mac（Designed for iPhone/iPad）运行需用户在 Xcode 登录后选 Personal Team；模拟器无需签名可直接跑。

## 6. 已知技术决策记录（实施期沉淀）

1. **GRDB 7 两个坑**：① `ValueObservation.tracking` 的 `-> Self where Reducer == ValueReducers.Fetch<Value>` 约束使方法标注 `-> ValueObservation<[T]>` 编译失败——observation API 推迟到 UI 接线阶段（阶段 4），届时用官方推荐模式；② 同时 conform `Codable` + `DatabaseValueConvertible` 的包装类型必须自定义 `init(from:)`（顶层数组语义），否则 record 解码报 "could not decode"。
2. **SQLite REPLACE 级联陷阱**：父行 `INSERT OR REPLACE` = DELETE+INSERT，会触发 CASCADE 清空子行；iOS 端一律 upsert，单测保护。
3. **双层 JSON.stringify 剥壳**：宿主模板 `JSON.stringify(fetchNotices())` × 脚本内 `return JSON.stringify(...)` 叠加，Swift 解码前需剥一层（对齐 Android kotlinx isLenient 行为）。
4. **Swift 6 严格并发**：DAO/Provider/Agent 层全部 Sendable；@Sendable 闭包内可变累积用 Box/Accumulator 模式；`parseDayArg`/SwiftSoup `attr` 等 throws 需显式处理。
5. **访问级别**：Agent/LLM 层当前为 **internal**（测试走 `@testable`）；**阶段 4 app 接线前需 public 化**。
6. Android 端文档错位提醒：`PLAN.md` 工具清单写 5 个实际 11 个、Room v11 实际 v14——以代码为准。

## 7. 目标架构（当前实际形态）

```
/Users/orange/OpenJWC_4ios/
├── app/                        # Android 参考克隆（真源：agent/ script/ data/ net/llm/）
├── Packages/OpenJWCCore/       # ✅ 阶段 1–3 产出：SwiftPM 域层包（iOS 18 / macOS 15）
│   ├── Package.swift           # GRDB 7.11.1 + SwiftSoup 2.8
│   ├── Sources/OpenJWCCore/    # Database / Models / Scripting / LLM / Settings / Agent（见 §5）
│   └── Tests/OpenJWCCoreTests/ # 40 tests（Swift Testing，@testable，含 3 项真实 Key 联测）
├── ios/                        # XcodeGen 占位 app（阶段 4 重建并接线 core）
├── openspec/                   # 已归档 ios-foundation-data-layer；阶段 4 立新案
├── docs/ios-port-roadmap.md    # 本文档（进度真源）
└── docs/script-format.md       # 脚本契约（Android 端文档）
```

## 8. 后续路线图（Tahoe 后开工）

**依赖链**：~~1 → {2, 3}~~（✅ 已完成）→ ~~等 Tahoe~~（✅ 2026-09-21 核验已升 26.6.2）→ {4, 5, 6} → 7 → 8。**阶段 4 当前可开工**，仅剩 D9（Xcode 版本）待用户拍板。

### 阶段 4 — 资讯 UI ✅（2026-09-21 完成，见 §5 阶段 4 小节；仅剩用户手验 9.3）
资讯流 / 源筛选 / 收藏 / 详情（Markdown 渲染）/ 图片查看器 / 通知深链跳转已全部实现并过自动化验收。附件选择器（长按加入附件）属收藏/附件管理细分，随阶段 5 Me 设置中心一并补。

### 阶段 5 — 聊天 + 日报 + Me 设置中心 ✅（2026-09-22 完成归档）

**OpenSpec change `ios-chat-daily-me`**（归档于 `2026-09-22-ios-chat-daily-me`），交付节奏 5a（core+聊天）/5b（日报+Me）两批验收，全部手验通过。

**产出**：
- core 新增：`ChatService`（发送编排：占位/事件逐条落库/重试不重插/历史裁剪 ≤20 条 ≤48KB/中断兜底）、`DailyReportService`（actor：8 条/批、>100 拒绝、48KB 合并阈值、COMPLETED 防覆盖）、`HitokotoClient` + `Motto` 按天缓存；public 化第二批（Agent/LLM/Chat/DailyReport 全链路）
- app 聊天 tab：轮结构消息流、**两阶段流式渲染**（纯 Text 100ms 合并 → 完成 Markdown，规避 MarkdownUI O(N²) 重解析——上游 #426/#445）、三态滚动跟随、**发送/停止一键切换**（iOS 增强，超出 Android 基线）、工具活动折叠容器（生成中自动展开/结束收起「N 个工具 · X 秒」/read_notice 深链）、附件引用三层选择、失败与停止共用重试行 + configRelated「去设置」、会话抽屉、LLM 多配置档案（10 预设/Keychain/测试连接按状态码归类错误）
- app 日报 tab：日期 chips + 四态 + 手动生成/重试；**Me 完整版**：Hitokoto 头部（按天缓存懒刷新）、设置中心（AI 模型多档案/显示设置 freshDays·crawlDaysGap/来源编辑器三页含导入 .js 校验注册/格言设置 11 分类）、关于 + 用户协议（README 原文 Bundle 资产渲染）
- 主流实现对照已记入 proposal（ChatGPT/Claude 交互、HIG 生成式 AI、Vercel smoothStream 节流、GRDB 单闭包多表观察官方模式）
- 用户创意待办：对话页样式选择（tasks 10.1，阶段 8）

**自动化验收**：离线 `swift test` **71 tests / 16 suites 全绿**（基线 40 → 阶段 4 增 11 → 阶段 5 增 20）；全外网套件（39 源冒烟/ScriptAcceptance/LLMKey）单跑。模拟器全场景手验通过（含停止、重试、深链、日报生成、motto 双模式、来源编辑、导入脚本、进度面板全局化）。

```bash
cd /Users/orange/OpenJWC_4ios/Packages/OpenJWCCore
swift test --skip AllSourcesSmoke --skip ScriptAcceptance --skip LLMKeyAcceptance 2>&1 | grep "Test run with"
# 期望：✔ Test run with 71 tests in 16 suites passed
```

### 阶段 6 — 课表（实施中：6a 完成待手验，6b 未开始）
周视图自定义 Layout（lane/segment 直译）/ 编辑器 / 长按拖拽 + 弹性落点 / JSON 导入导出。
**立案**：`openspec/changes/ios-timetable/` 四件套已评审通过（方案 b = JSON 导入先行、WebView 教务导入延后另立 change，决策与主流方案对照见 design D-6/D-6-补）。
**6a 已完成**（`7b5777d` + `b604f4d` + `f1f597c`）：
- core 新增 `Timetable/`：`TimetableLayout`（泳道三步算法/落点解算/冲突判定/周次文案）、`TimetableJson`（**stableJavaHash 双端同色**、weeks 三态解析、13 节扩展、导出回环）、`TimetableService`（表 CRUD/导入事务）；`TimetableDao` public 化 + 观察静态查询 + `updateCoursePosition` 专用 UPDATE
- app 课表 tab 转正：周翻页（TabView .page 双向同步）、背景 Canvas、节次标签/日期表头（今天高亮）、时间指示线、课程分层（本周全列宽/非本周泳道淡显/拖动露层）、**长按拖拽全链路**（浮层 spring 长到整列/220ms 落位回弹/数据反映撤浮层 + 1s 兜底）
- 拖拽状态机重构（手验反馈驱动）：状态单源化进 `TimetableDragState`（gestureAlive/canStart/reset 全量归零），块手势用 **@GestureState 自动复位**消除中断泄漏；moveCourse 改专用 UPDATE 杜绝复制行
- 离线 `swift test` **98/19 全绿**（+27 项：布局/JSON/Service）；模拟器验证网格/表头/示例课渲染正确
**6a 遗留**：待用户拖拽手验（落位/回弹/翻页/高亮）；「单列字符」现象待 6b 定位（疑周次失配走泳道半列宽）
**6b 未开始**（tasks 组 5–8）：课程详情/编辑器、表管理（菜单/选择/配置）、JSON 文件导入导出、AgentRuntime 注入 GrdbTimetableSource、Me 课表设置页；DEBUG 临时件（魔棒/示例数据/-startTimetable 参数）随 6b 移除
**交接**：调研指令与实施节奏见 `docs/ios-stage6-handoff.md`。

### 阶段 7 — 平台集成（Tahoe 后）
BGTaskScheduler 抓取 + 日报 / 通知 + 深链 / 课程提醒 / WidgetKit。**注意语义差异**：iOS 后台调度不保证 Android WorkManager 的准 15 分钟轮询（产品文案要写）。

### 阶段 8 — 打磨发布（Tahoe 后）
Liquid Glass **兜底全覆盖**（策略：各 UI 阶段实现时即就地采用 `if #available(iOS 26.0, *)` 玻璃效果，本阶段统一查漏）/ Dynamic Type / Dark Mode / xcstrings 5 语言（zh/en/ja/ko/zh-rTW，对齐 Android 4 套 values）/ 三层图标（从 Android `res/` 提取重绘，无设计资产仓库）/ 免费签名侧载 / 隐私文案（强调非官方）。

## 9. 风险清单

1. **后台时效**：BGTaskScheduler 不保证准 15 分钟轮询（高，产品级）。
2. **39 脚本全量回归**：SwiftSoup 对 Jsoup 扩展选择器（`tr:has()` 等）的等价性需逐脚本验证，阶段 4 验收期集中兜底（中；已抽验 3 站全过）。
3. **双平台长跑**：Android 活跃开发，iOS feature lag（中，PLAN.md 为真源）。
4. **磁盘长期紧张**：~~当前 22G~~ 2026-09-21 实测可用 62G，短期无虞；UI 阶段 DerivedData 会增长，定期清（低，可管理）。
5. **SwiftUI Preview 保真度**：玻璃特效与真机有差异，终验以模拟器/真机为准（低）。
6. **SDK 版本选择**：✅ D9 已落定 Xcode 26.6；2027 年 Apple 全面 Tahoe-only 需换环境（远期）。

## 10. 新会话启动指引

1. **必读顺序**：本文档 → Android 真源目录（`app/src/main/java/org/openjwc/client/`）。
   （注：原指引引用的 ZCode `MEMORY.md` 及其索引 6 篇在本工作区不存在，ai-memory 服务器未接入当前会话；本文档已按「自包含」标准补全，2026-09-21 接手会话实测可独立开工。）
2. **状态查验**（先跑再说）：
   ```bash
   sw_vers | grep ProductVersion            # ✅ 26.6.2 Tahoe
   xcodebuild -version                       # ✅ 26.6 (17F113)
   cd /Users/orange/OpenJWC_4ios/Packages/OpenJWCCore && swift test --skip AllSourcesSmoke --skip ScriptAcceptance --skip LLMKeyAcceptance 2>&1 | grep "Test run with"
   # 期望 71 tests / 16 suites passed（全外网套件单跑：AllSourcesSmoke ~25min；
   # 离线跑全量时外网用例失败属正常）
   ```
3. **接手场景**：
   - ✅ 阶段 4/5 已完成归档 → 下一阶段 6 课表：OpenSpec 立案 → 实施（参考 §8 阶段 6 小节）。
   - iOS 端当前形态：五 tab 中四 tab 已转正（对话/日报/资讯/我的），仅课程表占位。
4. **流程纪律**：非平凡改动走 OpenSpec（proposal→specs→design→tasks→用户评审→实现→archive）；用户偏好决策征询格式（决策点/候选/利弊表/推荐/追问）。
5. **待用户确认项**：~~D8 删 runtime~~（已执行）；~~Tahoe 升级~~（✅ 26.6.2）；~~真实 LLM Key~~（联测完成，Key 留存 `~/.openjwc-llm-key`）；~~D9 Xcode 版本~~（✅ 26.6）；~~阶段 4/5~~（✅ 均已归档）。**无待办阻塞，阶段 6 课表可立案。**

### Xcode 选型记录（D9，✅ 2026-09-21 落定：方案 A，Xcode 26.6）

**结论**：升级至 **Xcode 26.6 (17F113)**（26 系列最终稳定版，Swift 6.3 / iOS 26.5 SDK）。验证：`xcodebuild -version` 确认 26.6；`swift test` 复验 **40 tests / 10 suites passed**（84.5s，含真实抓取与真实 Key 联测）；xip（2.3G）验证通过后已清理。用户 xip 渠道安装（App Store 渠道未采用）。

**当时调研对比存档**（来源：developer.apple.com/xcode/system-requirements，2026-09-21 查询）：

| Xcode | 系统要求 | SDK | Swift 编译器 | 状态 |
|---|---|---|---|---|
| 26.3（升级前） | Sequoia 15.6 – Tahoe 26.x | iOS 26.2 | 6.2.3 | 稳定 |
| 26.4.1 | Tahoe 26.2+ | iOS 26.4 | 6.3 | 稳定 |
| 26.5 / 26.6 | Tahoe 26.2+ | iOS 26.5 | 6.3 | 稳定（26.6 = 26 系列最新） |
| 27 (27A266a) | **Tahoe 26.6+** | iOS 27 | 6.4 | 稳定但 2026-09-14 刚发（.0） |
| 27.1 / 27.2 beta | Tahoe 26.6+ | iOS 27.1/27.2 | 6.4 | beta |

**关键差异点**：① Xcode 26.3 及更旧版本在 macOS 26.4+ 上跑 ASan/TSan 会挂起（官方已知问题，workaround = 用 26.4+）；② 26.4+ 的 App Store 渠道在 Tahoe 上已可用（此前 Sequoia 装不上）；③ 26 系列部署目标均支持 iOS 15+，满足 D6 的 iOS 18 baseline 与 Liquid Glass（26.0+ API，26.2 SDK 已覆盖）。

**候选方案**：
- **A（推荐）：升 Xcode 26.6**——26 系列最终稳定版，与用户选 Tahoe 26.6.2「最终版最稳」策略一致；Swift 6.3、iOS 26.5 SDK；消除 sanitizer 已知问题；App Store 或 xip 均可装。
- B：留 26.3——零下载成本，阶段 4–6 功能上够用；缺点：sanitizer 挂起、Swift 6.2.3 渐旧、26 系列将停止接收 App Store 提交类支持（本项目免费侧载不受影响，属远期）。
- C：升 Xcode 27.0——**不推荐**：.0 发布仅 7 天且 27.1/27.2 beta 已在滚（印证修复期）；iOS 27 SDK 非本项目所需；与用户避开 macOS 27.0 的策略自相矛盾。

**安装路径（实际采用）**：xip 渠道（developer.apple.com/download/all，2.3G），解压覆盖 `/Applications/Xcode.app`，`xcode-select` 路径不变。装完验证：`xcodebuild -version` → 重跑 `swift test`（40/10 基线）✅。
