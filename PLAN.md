# 去云端改造计划（纯本地 + BYOK）

> **状态注记**：本文档为 **Android 端**的改造计划（上游）；部分条目（工具数量、Room 版本）与代码有滞后，以代码为准。iOS 移植版的计划与进度见 [`docs/ios-port-roadmap.md`](docs/ios-port-roadmap.md)。

目标：逐步移除自建 Go 服务端，改为「本地数据源脚本 + 自带 API Key 直连 LLM + 本地 Agent」。
分支：`feat/on-device-ai`。

## 已确认决策

- 资讯抓取：**侧载脚本**（QuickJS + Jsoup），内置脚本覆盖后端现有站点。
- 订阅语义：**订阅 = 抓取开关**；未订阅只存脚本不抓。
- 资讯筛选：**只按数据源**筛选。
- 聊天/日报：放弃端侧模型，改用**用户自带 API Key** 直连各大厂商。
- DB：直接改 schema（Room 7 → 8）。
- 内置脚本范围：后端现有 3 站 13 栏目（东南大学 jwc / cs / xsxy）。

## 内置脚本清单（复刻 `site.go` + `ingest.go`）

| id | host | 栏目 | 列表选择器 | 正文 |
|---|---|---|---|---|
| `jwc` | jwc.seu.edu.cn | 最新动态 `/zxdt/list.htm`、教务信息 `/jwxx/list.htm`、学籍管理 `/xjgl/list.htm`、教学研究 `/jxyj/list.htm`、实践教学 `/sjjx/list.htm`、国际交流 `/gjjl/list.psp`、文化素质教育 `/cbxx/list.htm` | `tr` 含 `td.main`，取 `a[title]` | `.Article_Content` |
| `cs` | cs.seu.edu.cn | 学院新闻 `/news/list.htm`、通知公告 `/49342/list.htm`、学术活动 `/xshd_53564/list.htm` | `li.news`（含 `.news_title` + `.news_meta`），取 `a[title]` | `.wp_articlecontent` |
| `xsxy` | xsxy.seu.edu.cn | 新闻动态 `/57140/list.htm`、通知公告 `/57141/list.htm`、人才培养 `/57151/list.htm` | 同上 | `.wp_articlecontent` |

复刻规则：`id = sha256(detailUrl)`；`date = 行文本中 \d{4}-\d{2}-\d{2}`；`isPage = 后缀不是 .pdf/.doc/.docx/.xls/.xlsx/.zip/.rar`；`contentText` 取正文元素文本；`attachments` 取正文内附件链接；只取 `freshDays` 内；UA `OpenJWC/1.0`。

---

## P0 — LLM 接入层 + Key 存储 + Provider 设置页

**目标**：解锁聊天/日报/agent。

**新增**
- `net/llm/LlmModels.kt`：`Protocol`、`LlmProviderConfig`、`LlmMessage`、`LlmToolSpec`、`LlmDelta`、`LlmException`。
- `net/llm/LlmClient.kt`：`interface LlmClient { fun streamChat(...): Flow<LlmDelta> }`。
- `net/llm/OpenAiCompatibleClient.kt`：`/chat/completions` 流式 + `tool_calls` 累积。
- `net/llm/LlmPresets.kt`：OpenAI/DeepSeek/Kimi/GLM/Qwen/OpenRouter/Ollama 等预设。
- `net/llm/LlmClientFactory.kt`。
- `data/datastore/LlmSettingsDataSource.kt`：provider/baseUrl/model（DataStore）。
- `data/datastore/LlmKeyStore.kt`：EncryptedSharedPreferences 存 Key。
- `ui/me/settings/llm/LlmSettingsScreen.kt`、`viewmodels/LlmSettingsViewModel.kt`。

**修改**：`gradle/libs.versions.toml`、`app/build.gradle.kts`、`navigation/Screen.kt`、`navigation3/NavContainer.kt`、设置入口、strings×5。

**验收**：填 Key → 测试连接成功；流式输出可见；`tool_calls` 能解析；Key 不进 logcat（独立 OkHttpClient，不挂 `loggingInterceptor`）。

---

## P1 — 本地 Agent 循环 + 工具集

**新增**：`agent/LocalAgentLoop.kt`、`agent/AgentTools.kt`（`search_notices`/`get_notice`/`list_sources`/`list_labels`）、`agent/PromptTemplates.kt`。

**验收**：本地数据上多轮 tool_calls 能作答；超轮/超时/无网受控。

> 实际实现（对齐后端 `internal/service/agent/`）：
> - 新增 `agent/`：`AgentModels.kt`（`AgentRequest`/`AgentMessage`/`AgentEvent`/`AgentFailure`）、`AgentBudget.kt`（默认 8 轮 / 16 调用 / 4 每轮 / 16KB 单次 / 96KB 累计 / 45s 模型 / 120s 运行）、`PromptTemplates.kt`（系统提示 + 工具说明 + 元数据）、`AgentTools.kt`、`AgentLoop.kt`。
> - **工具集采用结构化工具**（非后端受限 Shell）：`search_notices`（关键词/栏目/数据源/日期区间/排序/分页）、`read_notice`（按字符偏移续读，≤12000 字符）、`list_labels`（含条数）、`list_sources`、`current_time`。
> - `AgentLoop` 与后端同构：系统提示+元数据+历史 → 多轮「模型(带工具) → 执行工具 → 观察」→ 预算耗尽时补占位观察并做一次**禁用工具**的收束请求；工具轮正文不流式公开。
> - 与后端一致：任何一轮确认「没有工具调用」后，都会再发一次**禁用工具**的流式请求产出最终答案
>   （`streaming-final` 逐字输出；仅当供应商不支持 SSE 时才整体缓冲为 `buffered-final`）。
>   代价是每次回答多一次模型调用，换来真流式与更规范的带引用答案。
> - 新增 `data/repository/NoticeCorpus.kt`：Agent 只依赖的只读语料接口，`NewsRepository` 实现它，便于单测。
> - 单测 `app/src/test/java/org/openjwc/client/agent/AgentLoopTest.kt`（4 例：工具轮→终答、无工具直答、工具失败可继续、每轮工具超限收束），全部通过。

---

## P2 — 资讯脚本化

### P2.1 脚本宿主
新增 `script/ScriptManifest.kt`、`script/ScriptApi.kt`、`script/QuickJsScriptHost.kt`。
脚本契约：`function fetchNotices(): string`（返回 JSON 数组），桥提供 `http.get/post`、`html.query/text/attr`、`util.sha256/resolveUrl`、`console.log`。
**验收**：内置脚本后台跑出 `List<FetchedNotice>`；超时受控。

### P2.2 数据源注册表 + DB 迁移
新增 `data/models/SourceEntity.kt`、`data/dao/SourceDao.kt`、`data/source/SourceRegistry.kt`。
修改 `data/db/AppDatabase.kt`（v7→8：+`notice_sources`，`news_cache`/`news_cache_labels`/`favorite_notices` 主键 `host+port`→`sourceId`，+`news_fts`）及三个 Entity。
**验收**：旧数据映射为 `legacy:<host>:<port>`；新旧表读写正常。

> 实际实现（v10 语料重构）：
> - `news_cache` + `favorite_notices` 合并为统一语料表 **`notices`**
>   （`id` PK、`sourceId`、`label`、`title`、`publishedAt`(epoch)、`publishedDay`(yyyy-MM-dd)、
>   `detailUrl`、`isPage`、`content`、`attachments`、`fetchedAt`、`notified`、`favorite`；
>   索引：`publishedAt` / `publishedDay` / `(label, publishedAt)` / `sourceId`）。
>   收藏改为 `favorite` 标记，不再单独建表；**不再裁剪**，作为 Agent 可检索的知识库长期保留。
> - 新增 `daily_reports(day PK, status, content, sourceCount, updatedAt)`。
> - 新增 `data/dao/NoticeDao.kt`（资讯流 / 收藏 / 通知水位 / Agent 检索）与 `data/dao/DailyReportDao.kt`；
>   删除 `NewsDao.kt`、`NewsCacheEntity.kt`。
> - `MIGRATION_9_10`：建 `notices` + 从 `news_cache`（还原 `sourceId`）与 `favorite_notices` 灌入 + 删旧表 + 建 `daily_reports`。
> - 检索暂用 `LIKE '%q%'`（标题命中优先排序），未用 FTS：SQLite 默认分词器切不了中文，
>   后端靠的是 FTS5 `trigram`，Room 注解表达不了；几千行量级 LIKE 足够。

### P2.3 内置脚本
新增 `assets/sources/jwc.js`、`cs.js`、`xsxy.js`。
**验收**：字段与后端一致；只取 `freshDays` 内。

> 实际实现（v1.2.0，进一步对齐后端 `ingest.go` / `run.go`）：
> - **行匹配**：jwc 要求 `tr` 内**至少 2 个 `td.main`**（对齐后端 `isNoticeRow`）；cs/xsxy 仍要求同时含 `.news_title` 与 `.news_meta`。
> - **日期解析失败**计入 `failed`（不再静默 `continue`）。
> - **末页**：读取列表页 `.all_pages` 的文本作为末页（解析失败按 1），停止条件 `本页无窗口内条目 || page >= 末页`。
> - **详情失败不入库**：正文选择器未命中或 HTTP 失败时跳过该条并计入 `failed`，留给下次运行重试（不再写 null 正文，避免进 `knownIds` 后永不补齐）。
> - **统计与警告上报**：新增脚本桥 `report.stats(scanned, skipped, failed)` / `report.warn(msg)`（`ScriptReportApi`，`ScriptOutcome`），`SourceRunner` 汇总后写入 `lastError`（对齐后端 `progress` / `partialError`：结果照常入库，只提示）。
>
> 更早的 v1.1.0：
> - **翻页**：`list.htm` → `list2.htm` → …（每栏目上限 30 页），整页都超出回溯窗口即停止。
> - **抓取窗口**：用 `params.crawlCutoffDate()`（由「抓取回溯天数」`crawlDaysGap` 决定，默认 200 天），**与显示用的 `freshDays` 完全解耦**。
> - **去重补抓**：`params.knownIdsJson()` 给出该源已入库的 id，命中的条目直接跳过（不再重复抓正文）；单次运行正文抓取上限 120 条，未抓到的留给下次运行继续。
> - `ScriptParamsApi` 移除 `freshDays()`/`cutoffDate()`，改为 `crawlDaysGap()`/`crawlCutoffDate()`/`knownIdsJson()`；`SourceRunner` 沙箱上限提到 `maxHttpCalls=600`、`timeout=240s`。

### P2.4 数据源设置页
新增 `ui/me/settings/sources/SourcesScreen.kt`、`viewmodels/SourcesViewModel.kt`。
**验收**：列表/订阅开关（控制抓取）/删除/注册（文件·粘贴）/测试抓取/错误/调度间隔。

### P2.5 Worker + 仓库切换 + 筛选
新增 `work/SourceCrawlWorker.kt`；修改 `NewsRepository`（`DataSource.LOCAL|SERVER` 灰度）、`NewsCheckWorker`、`ui/news/NewsScreen.kt`（数据源筛选 chips）。
**验收**：只抓订阅源；按数据源筛选；通知水位正常；可切回服务端。

> 实际实现（偏差）：
> - 资讯流直接切本地（`NewsViewModel` 只走本地路径），**未做 `LOCAL|SERVER` 灰度开关**；服务端 `getLabels/getNews` 代码保留但已无人调用，待 P2.6 删除。
> - 新增 `SourceCrawlWorker` + `SourceCrawlScheduler`（`work/SourceCrawlWorker.kt`）；`NewsNotificationScheduler` 退化为门面。
> - `SourceRunner` 重构为 `fetch`/`crawl`/`settleNotifications`：抓取即写缓存（保留 `notified` 水位）+ 裁剪分区（200 行）+ 回写 `lastRunAt/lastCount/lastError`。
> - 周期抓取：有订阅源即排程；间隔 = 开通知时用 `newsCheckIntervalMinutes`，否则用数据源 `@schedule` 最小值（下限 15 分钟）。
> - `NewsScreen`：`FilterChip` 数据源筛选行（>1 个源才显示）+ 空态改为引导「管理数据源」。
> - 已知问题：内置脚本会为每条资讯抓正文详情，整轮抓取较慢（下拉刷新会同步等待）；后续可改为「列表只抓标题 + 详情按需抓取」。

### P2.6 删服务端资讯
删除 `net/news/FetchNews.kt`、`NetService.getNotices/getLabels`、`NewsRepository` 服务端分支。

> 已完成：
> - 删除 `net/news/FetchNews.kt`、`work/NewsCheckWorker.kt`。
> - `NetService` 移除 `getNotices` / `getLabels`。
> - `NewsRepository` 移除服务端资讯/标签缓存方法（保留 `uploadNews`/`getReviewedNews` 给 P5）。
> - `NewsModels` 移除 `FetchNewsResponseData`/`FetchLabelsResponseData`；`NewsDao` 移除 `news_cache_labels` 与分区内按 label 的旧查询。
> - Room v8→9：移除 `NewsLabelCacheEntity` + `MIGRATION_8_9` 删表。

---

## P3 — 聊天切本地 Agent
改 `ChatRepository`/`ChatViewModel`/`ChatScreen`；删 `net/chat/ChatStreamClient.kt`、`ChatProtocolState.kt`、`NetService.postChat`。

> 已完成：
> - `ChatRepository` 改为直接用用户 Key 驱动 `AgentLoop`（`LlmSettingsDataSource` + `LlmKeyStore` + `LlmClientFactory`），不再经过自建服务端。
> - Room v10→v11：`chat_messages` 新增 `status`/`runId`/`delivery`/`errorCode`；新增 `chat_tool_calls(messageId FK, position, name, summary, status, code, durationMs)`。
> - 工具轨迹随消息落库 → **工具卡片重启后可还原**；UI 不再依赖内存 `runningTools`，`ChatViewModel.turns: StateFlow<List<ChatTurn>>` 由 DB 驱动。
> - 历史只回放 `status=COMPLETED` 的 user/assistant 文本（≤20 条 / 48KB）；**删除**了「把历史附件伪装成 user JSON 消息」的旧 hack，附件改走结构化 `noticeIds`。
> - 失败保留部分正文与工具轨迹（`status=FAILED` + `errorCode`）；无任何产出时才删除空壳助手消息。
> - `agent_configuration_error` → 新增 `NavEvent.ToLlmSettings`，聊天页自动跳转「AI 模型设置」。
> - 删除 `net/chat/`（`ChatStreamClient`/`ChatProtocolState`/`SseParser`）、`net/models/ChatModels.kt`、`NetClient.getChatHttpClient`。

## P4 — 日报本地化
新增 `data/models/DailyReportEntity.kt`、`data/dao/DailyReportDao.kt`、`agent/DailyReportGenerator.kt`、`work/DailyReportWorker.kt`；删 `net/dailyreport/FetchDailyReport.kt`。

> 已完成（对齐后端 `internal/service/digest`）：
> - `DailyReportEntity`/`DailyReportDao` 已在 v10 建表；`DailyReportRepository` 实现生成流程：
>   按 `publishedDay` 取当日 id（>100 条拒绝）→ 状态 `running` → 每 8 条一批交给 Agent 摘要
>   → 多批时再跑一次合并（拼接超 48KB 则跳过合并直接拼接）→ `completed`；失败写 `failed`，不发布半成品。
> - `AgentLoop.answer()` 便捷入口（只收集 `AnswerDelta`，失败抛 `AgentRunFailedException`）；
>   新增 `agent/AgentLoopFactory.kt`（按用户配置 + 加密 Key 构造 `AgentLoop`，聊天与日报共用）。
> - `DailyReportViewModel` 改为读本地：`observeCompletedDays()` + `latestCompleted(today)` + `getCompleted(day)`，
>   并新增手动「生成昨日日报」（空态按钮）。
> - `work/DailyReportWorker.kt` + `DailyReportScheduler`：24h 周期、初始延迟到用户设定的 `dailyReportTime`，仅在 `dailyReportEnabled` 时排程。
> - 设置：`UserSettings.dailyReportEnabled` / `dailyReportTime`（HH:mm），入口放在「通知」设置页新增的「日报」分组。
> - 删除 `net/dailyreport/`、`net/models/DailyReportModels.kt`、`NetService.getDailyReportToday/ByDate`。

## P5 — 账号 / 设备 / 投稿清理
删 `AuthRepository`/`AuthDataSource`/`AuthViewModel`、`Login/Register/AccountScreen`、`net/auth/*`、`UploadNewsScreen`、`ReviewedNoticesScreen`、`AuthEvents` 及 `NetService` 相关方法。

> 已完成（顺带移除整个自建服务端客户端）：
> - 删除 `AuthRepository`/`AuthDataSource`/`AuthViewModel`/`CachedDataSource`、`ui/me/settings/auth/`、`ui/me/settings/connection/HostScreen.kt`、`ReviewedNoticesScreen`、`ui/news/upload/`、`net/auth|news|hitokoto/`、`net/models/{NetClient,FetchedData,AuthModels,UploadNewsModels,ReviewNewsModels,HitokotoModels}.kt`。
> - `NetService` 已无任何端点 → 服务端客户端整体移除；`NetworkResult`/`SuccessResponse`/`fetch`/`networkJson` 抽到 `net/models/NetResult.kt`（仅检查更新在用），`Proxy` 抽到 `net/models/Proxy.kt`。
> - `UserSettings` 移除 `host`/`port`/`useHttp`（保留 `proxy` 给检查更新）；`SettingsRepository` 瘦身为纯 DataStore 读写。
> - `Screen` 移除 `Host`/`Login`/`Register`/`Account`/`UploadNews`/`Review`；`NavEvent` 只剩 `ToBack`/`ToLlmSettings`。
> - `motto` 本地化为 `data/models/Motto.kt`（`LOCAL_MOTTO`），`MeViewModel` 只剩本地格言。

## P6 — 设置 / 杂项 / 政策
`HostScreen` 退役；`UserSettings.host/port/useHttp` 移除；`motto` 本地化；`PolicyScreen` 文案重写；i18n 清理；依赖清理。

## P7 — 收尾与回归
`NetService` 只剩检查更新；全量回归；迁移测试；合规复核。

## 依赖关系
```
P0 ─┬─ P1 ─┬─ P3
    │      └─ P4
    └─ P2.1 ─ P2.2 ─ P2.3 ─ P2.4 ─ P2.5 ─ P2.6
P5 依赖 P2.6 + P3 + P4
```

## 技术验证结论
- `org.jsoup:jsoup:1.18.3`：Maven Central 可用。
- `app.cash.quickjs:quickjs-android:0.9.2`：Maven Central 可用（AAR ~1.5MB，含 arm64/armv7/x86/x86_64 原生库）；API：`create/evaluate/set(name,Class,value)/close`，无内存限制/中断 API → 超时用独立线程 + `Future.get` 实现。
