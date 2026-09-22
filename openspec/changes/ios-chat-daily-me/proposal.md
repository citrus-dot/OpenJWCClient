# Proposal: ios-chat-daily-me

## Why
阶段 4 资讯 UI 已归档。iOS 端 on-device 路线仍缺三大交互块：聊天（本地 Agent 工具循环的 UI 面）、日报（本地语料的 LLM 日报生成与展示）、Me 设置中心（LLM 配置、motto 格言、来源编辑器、资讯显示设置、关于/协议）。没有这三块，iOS 端无法完成「功能不缺失」（D10 对照基准）的核心闭环：用户抓取的资讯 → 引用提问 → Agent 工具循环 → 日报沉淀。

## What Changes
- **core 扩展**（域层，供阶段 7 后台任务复用）：
  - public 化第二批：`AgentLoop`/`AgentTypes`/`AgentTools`（摘要展示面）、`LlmClient`/`LlmKeyStore`、`ChatDao` 与 `Models/Chat.swift`、`DailyReportDao`
  - 新增 `ChatService`（对齐 Android `ChatRepository`：消息落库、工具卡落库、Agent 事件 → 状态流转、失败码语义、历史裁剪 ≤20 条 ≤48KB）
  - 新增 `DailyReportService`（对齐 `DailyReportRepository`：Mutex 串行、BATCH_SIZE=8、MAX_SOURCES=100、48KB 合并阈值、running/completed/failed 五写点）
  - 新增 `HitokotoClient`（对齐 `HitokotoClient.kt`：v1.hitokoto.cn、11 分类、min/max_length、超时）+ `Motto` 模型与按天缓存（UserDefaults 单 JSON key）
  - 修复 `AgentLoop` 跨帧 tool_calls 索引未排序问题（对齐 Android `toSortedSet`）
- **app 新增**（SwiftUI）：
  - 聊天 tab：会话列表（新建/重命名/删除）、消息流（气泡 + 工具时间线）、附件引用资讯（NewsAttachmentSheet 等价）、失败重试行、`read_notice` 工具卡深链资讯详情、`configRelated` 失败跳 LLM 设置
  - 日报 tab：日期 chips（最新标记）、四态（生成中/失败/空态/Markdown 正文）、手动生成 + 下拉刷新
  - Me tab：HitokotoView 头部（在线一言/本地格言 + 懒刷新）、设置中心（LLM 配置含 10 预设与测试连接、日报开关、格言设置、来源编辑器（订阅/抓取/脚本查看编辑/导入）、资讯显示设置（freshDays/crawlDaysGap））、收藏入口、关于页、用户协议页
- **app 组装**：`AgentRuntime`（LlmKeyStore + SettingsStore → LlmClient 组装，对齐 AgentLoopFactory）；聊天/日报/motto 三处响应式桥接（变更信号观察 + 命令式重读，沿用阶段 4 模式）

## Non-goals
- 日报/抓取的**后台调度**（BGTaskScheduler）与系统通知 → 阶段 7
- 主题 / 语言 / 通知设置 / 课表偏好 / 小组件设置 → 各自阶段（6/7/8）
- 侧载脚本之外的云端功能（D10 已裁剪）
- 首启协议弹窗（Android `PolicyDialog` 无调用点，iOS 同样不弹，仅提供协议页）

## Impact
- core：约 6 处 public 化 + 3 个新文件（ChatService/DailyReportService/Hitokoto+Motto）；既有 51 测试必须保持绿
- app：新增 Features/Chat、Features/DailyReport、Features/Me 三个目录；`AppShellView` 四个占位 tab 中三个转正（仅 Timetable 保持占位）
- 风险：聊天 UI 是全 app 最复杂的交互面（流式 + 工具卡 + 多状态机），拆组实施、每组有单测或明确的手验点
