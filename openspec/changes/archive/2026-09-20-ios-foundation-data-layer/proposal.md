# Proposal: ios-foundation-data-layer

## Why

方案 b（SwiftUI 原生重写）已定，iOS 26 开发环境已验收（Xcode 26.3 + iOS 26.3.1 模拟器）。Roadmap 阶段 1 的目标是把整个 App 的地基打出来：工程骨架 + 持久化层。数据层是后续脚本宿主（阶段 2）、Agent（阶段 3）、UI（阶段 4–6）的共同依赖，必须先行且与 Android 端语义对齐，否则两端数据行为漂移（通知水位、Agent 检索排序、工具卡还原）会渗透到所有上层。

## What Changes

- 域层落在 **SwiftPM 包 `Packages/OpenJWCCore`**（双平台声明 iOS 18 / macOS 15，对齐 D6/D7：Tahoe 前域层用 macOS `swift test` 驱动，UI 层 iOS 18 baseline + 26 玻璃增强）。`ios/` XcodeGen 占位工程保留，阶段 4（Tahoe 后）接线 core 包。
- 集成 **GRDB 7.11.1**（SPM，实测远端最新 tag，8.x 不存在——已修正调研期的版本误报），按 Android Room **v14 终态 schema** 建 8 张表：`notices`、`daily_reports`、`notice_sources`、`chat_metadata`、`chat_messages`、`chat_tool_calls`、`courses`、`table_metadata`，含索引与外键级联——逐列对齐，含 v13/v14 迟到列（`notices.contentVersion`、`chat_tool_calls.targetId`）。
- **不做迁移链**：iOS 全新安装，直接建终态 schema（Android 的 v2→v14 迁移历史不搬运），版本号从 1 起步。
- Keychain 封装的 LLM Key 存取（对位 Android `LlmKeyStore`/EncryptedSharedPreferences，按 providerId 索引、`AfterFirstUnlockThisDeviceOnly`）。
- UserDefaults 封装的用户设置存取（对位 `UserSettings`：LLM 配置单键 JSON + 全字段逐 key 默认值 + `deletedSourceIds`，阶段 1 仅落地数据访问，无 UI）。
- 全部带 XCTest 单测（in-memory DB + 临时文件 DatabasePool 测 WAL 并发）。

## Non-goals

- 脚本宿主（JavaScriptCore，阶段 2）、AgentLoop（阶段 3）、任何 UI 界面（阶段 4–6，等 Tahoe）。
- GRDB ValueObservation 流式 API（推迟到 UI 接线阶段，本阶段 DAO 仅快照查询——spec 无此硬要求）。
- 通知 / 后台任务 / Widget（阶段 7）。
- Android 端任何改动。
- 与 Android 的数据互导（两端独立，schema 语义对齐即可）。

## Impact

- 新增目录 `ios/`、`openspec/`（本工作流）。
- 风险：GRDB API 与 Room 语义差异（枚举存储、List 序列化、级联删除行为、`@Insert(REPLACE)` 的 DELETE+INSERT 级联陷阱）——用单测逐表锁定（详见 design.md「REPLACE 级联陷阱」）。
- 验收标准：`xcodebuild test`（iPhone 17 Pro 模拟器）全绿。
