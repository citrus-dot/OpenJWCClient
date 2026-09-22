# Design: ios-chat-daily-me

## 架构总览

```
Packages/OpenJWCCore 新增（域层，阶段 7 BGTask 复用）
├── Chat/ChatService.swift            # Android ChatRepository 直译：发送编排 + 事件落库 + 历史裁剪
├── DailyReport/DailyReportService.swift  # Android DailyReportRepository 直译：生成编排 + 状态机
└── Motto/HitokotoClient.swift        # hitokoto.cn 客户端 + Motto/CachedMotto + 按天缓存

core public 化第二批（D-4）
├── Agent/AgentTypes.swift + AgentLoop.swift + AgentTools.swift（displayName/summary 面）
├── LLM/LlmClient.swift（协议 + 事件）+ LlmKeyStore.swift
├── Database/DAO/ChatDao.swift + Models/Chat.swift（4 record + ChatTurn）
└── Database/DAO/SourceDao.swift 内的 DailyReportDao

ios/OpenJWC 新增
├── App/AgentRuntime.swift            # D-3 组装：SettingsStore + LlmKeyStore → LlmClient → AgentLoop
├── Features/Chat/
│   ├── ChatStore.swift               # 会话状态机 Map + 生成中文本 + FailedTurn（对齐 ChatViewModel）
│   ├── SessionListView.swift         # 会话抽屉（新建/重命名/删除）
│   ├── ChatView.swift                # 消息流（轮 = 工具时间线 + 气泡）+ 输入区 + 附件 sheet
│   ├── MessageBubble.swift / ToolCardView.swift / AttachmentSheet.swift
├── Features/DailyReport/
│   ├── DailyReportStore.swift / DailyReportView.swift
└── Features/Me/
    ├── MeView.swift                  # Hitokoto 头部 + 入口
    ├── MottoStore.swift              # motto 取值优先级 + 懒刷新（对齐 MeViewModel）
    ├── Settings/SettingsHomeView.swift
    ├── Settings/LlmSettingsView.swift
    ├── Settings/MottoSettingsView.swift
    ├── Settings/SourcesEditorView.swift（列表 + 详情 + 脚本编辑三页）
    ├── Settings/NewsDisplaySettingsView.swift
    └── AboutView.swift / PolicyView.swift
```

## 关键设计决策

### D-1 编排放 core，UI 状态放 app
`ChatService` / `DailyReportService` / `HitokotoClient` 全部进 core：它们是纯域层编排（DAO + AgentLoop + HTTP），阶段 7 的 BGTask/通知要直接复用（Android 的 Worker 也复用 Repository）。UI 状态机（ChatStore 的会话状态 Map、生成中文本、FailedTurn）留在 app 层，对齐 Android ChatViewModel 职责。

### D-2 聊天响应式：变更信号 + 命令式重读
ChatTurn 组装是多表手写逻辑，不做 ValueObservation 直观察。方案：对 `chat_sessions` 与 `chat_messages` 各挂一条轻量观察（tracking 版本计数：行数 + MAX(updatedAt)），变化时触发 Store 命令式重读（sessions 全量 / 当前会话 turns）。与阶段 4 noticeCount 驱动重读同模式。ChatDao 新增三个静态同步查询 `sessionsVersionSync` / `messagesVersionSync(sessionId:)` / `dailyReportsSync`（完成稿日期倒序）供观察用。

### D-3 AgentRuntime（app 层组装根）
对齐 Android AgentLoopFactory：`AgentRuntime(settings:keystore:)` → 读 `LlmProviderConfig` + Keychain Key → 构造 OpenAI 兼容 LlmClient → `AgentLoop`。每次发送按当前配置新组装（用户改配置立即生效，无需重启）。

### D-4 public 化第二批（最小集）
`AgentTypes`（AgentEvent/AgentFailure/AgentBudget/AgentMessage）、`AgentLoop`（run/answer + init）、`AgentTools`（displayName/summaryOf 展示面）、`LlmClient`（协议 + LlmStreamEvent）、`LlmKeyStore`、`ChatDao` 全方法、`Models/Chat.swift` 全 record、`DailyReportDao`。语义零改动；51 测试保持绿。

### D-5 AgentLoop 排序修复
跨帧 tool_calls 索引收集处（AgentLoop.swift:375 `Array(Set(...))`）改为 `Set(...).sorted()`，对齐 Android `toSortedSet()`；多工具并发返回时保证确定性顺序。

### D-6 motto 缓存
UserDefaults 独立 suite `motto_cache` 单 JSON key（对齐 Android DataStore 单 key 语义）：`{text, author, source, permalink, date}`，`isFresh = date == 今天`。占位默认值与 Android `Motto.DEFAULT_ONLINE` 一致（首次进入不联网）。

### D-7 Markdown 渲染复用
assistant 气泡、日报正文、协议页均用 MarkdownUI（阶段 4 已接线主题），协议文档以 Bundle 资源 `PrivacyPolicy.md`（folder 资源，非 folder reference）打包。

### D-8 设置页范围
本阶段实现：LLM 设置（含测试连接、日报开关/时间）、格言设置、来源编辑器（三页）、资讯显示设置（freshDays/crawlDaysGap）、关于、协议。**不实现**：主题/语言（阶段 8）、通知设置（阶段 7）、课表偏好（阶段 6）。Me 首页入口按 Android 三项（设置/收藏/关于）+ Hitokoto 头部。

### D-9 聊天 UI 交互
- 轮结构：LazyVStack 按 messageId 分轮渲染；仅最后一轮在 Loading/ToolCalling/Generating 时显示 spinner
- 自动滚动锚定最后一条用户消息；非底部时显示回底按钮
- 气泡：user 右对齐纯文本 + 附件标题徽标；assistant Markdown；最大宽 0.85；长按菜单（复制/删除带确认）
- 工具卡：summary 折叠/展开（默认首行）；只有 read_notice + targetId 显示跳转；详情跳转前预取 notice（对齐 Android 预解析以复用 push 路由）
- 输入：TextEditor + 发送键；输入截断 10000 字；生成中禁发（无停止按钮，对齐 Android）
- 失败：RetryRow 固定插在最后一条用户消息之后；`configRelated` 错误附「去设置」跳 LLM 设置

### D-10 iOS AgentLoop 取消语义对接
iOS AgentLoop 把 CancellationError 转为 `runFailed(agent_cancelled)` 事件（与 Android rethrow 不同）。ChatService 按错误码区分：`agent_cancelled` / `agent_interrupted` / `agent_failed` 均落 FAILED 终态，UI 统一失败态 + 重试；不重复落库。

## project.yml 变更
无（无新依赖；MarkdownUI 已有）。

## 边界与错误处理
- LLM 未配置即发送：Agent 循环首个事件即 runFailed(config_missing) → 失败态 + 去设置。
- 日报生成中杀 App：RUNNING 状态残留 → 下次进入该日展示可重试（generate 不覆盖 COMPLETED，但 RUNNING 可重新生成）。
- Hitokoto 请求失败：保留缓存 + 提示，不打断 Me 页。
- 测试连接超时 30s：结果区显示超时文案。

## 测试策略
- **core 单测**（Swift Testing，目标 51 → 约 60+ 全绿）：
  - ChatService：发送落库序（用户消息→占位→工具卡→终态）、重试不重复插用户消息、历史裁剪 ≤20 条 ≤48KB、中断落 agent_interrupted（假 LlmClient 事件序列注入）
  - DailyReportService：空日直完成、分批合并（8 条/批）、>100 条拒绝、COMPLETED 不可覆盖、失败截 300 字（假 LlmClient）
  - HitokotoClient：URL 构造（分类/长度参数边界 1..100）、响应解析、空 hitokoto 报错（URLProtocol stub）
  - Motto 缓存：按天 isFresh、本地模式默认值
- **UI 手验**：Mac/模拟器过 spec 场景；聊天流式用真实 Key 联测（Key 留存 ~/.openjwc-llm-key）。
