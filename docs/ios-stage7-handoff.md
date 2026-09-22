# 阶段 7（平台集成）立案调研交接文档

> **交接对象**：立案调研 agent。**状态（2026-09-22）**：阶段 6 课表已完成归档（`27817ef`，`openspec/changes/archive/2026-09-22-ios-timetable/`），五 tab 全部转正；**阶段 7 = 平台集成，本次立案**。前序阶段 4/5/6 均 OpenSpec 立案 → 用户评审 → 实施 → archive 全流程闭环，本案复制该模式。
> **本案范围（roadmap §8 阶段 7）**：BGTaskScheduler 后台抓取 + 日报 / 通知 + 深链 / 课程提醒 / WidgetKit 课程小组件。**已知语义差异（产品级风险，spec 必须写明）**：iOS BGTaskScheduler 不保证 Android WorkManager 的准 15 分钟轮询。
> **流程纪律**：OpenSpec 立案（proposal → specs delta → design → tasks → `openspec validate` → **NotifyUser 提交用户评审，不自行开工实施**）。发现 Android 与 iOS 平台能力错位时，在 spec/design 中标注裁剪或替代方案及理由（对齐阶段 6 拖拽挂起与 WebView 裁剪的先例）。
> **前置必读**（按序）：`docs/ios-port-roadmap.md` §8 阶段 7 小节 → 本文档 → Android 真源（下表）→ iOS 已有资产（下文）→ 既有四件套范例 `openspec/changes/archive/2026-09-22-ios-timetable/`。

## 一、调研范围（Android 真源）

平台集成横跨三模块，均在 `app/src/main/java/org/openjwc/client/`：

| 模块 | 文件 | 调研要点 |
|---|---|---|
| `work/`（后台任务） | `SourceCrawlWorker.kt`、`DailyReportWorker.kt`、`NewsNotificationScheduler.kt` | WorkManager 周期/约束/重试策略；抓取完成 → 新闻通知的编排链；日报定时生成的时间语义 |
| `notification/`（通知） | `NewsNotifier.kt`、`NewsNotificationContract.kt`、`NotificationNavigation.kt`、`CourseReminderContract.kt`、`CourseReminderScheduler.kt`、`CourseReminderReceiver.kt`、`ReminderRescheduleReceiver.kt`、`ReminderBootstrapper.kt` | 通知渠道/权限模型；新闻通知内容构造（新资讯聚合？逐条？）；**课程提醒排程算法**（提前量/重排时机/重启恢复 BOOT_COMPLETED）；点击深链路由 |
| `widget/`（课程小组件） | `CourseWidget.kt`、`WidgetDataManager.kt`、`WidgetUpdateScheduler.kt`、`WidgetSettingsManager.kt`、`CourseWidgetWorker.kt`、`ui/WidgetLayouts.kt`、`ui/WidgetTheme.kt`；Me 设置 `ui/me/settings/widget/WidgetSettingsScreen.kt`、`ui/me/settings/notification/NotificationSettingsScreen.kt` | 小组件数据管线（DB → RemoteViews）；刷新时机（Worker 驱动？）；显示配置项；Me 两个设置页的字段清单（对齐 `UserSettings` 已有字段） |

配套数据/设置层（iOS 已有，核对接口匹配即可）：
- `UserSettings`（iOS `SettingsStore.swift`）**已备好未接线**：`newsNotificationEnabled`、`newsCheckIntervalMinutes`、`courseReminderEnabled`——立案时核对该三字段与 Android 设置页字段是否一一对应，缺的补字段。
- iOS 通知深链链路**已部分实现**（阶段 4/6）：`NotificationDelegate`（`willPresent` 前台横幅 + `didReceive` → AsyncStream）→ `AppRouter.enqueueDeepLink` → `AppShellView .task(id:)` 消费；`DeepLink(destination:newsId:)`；`destNews`/`destNewsDetail`/`destTimetable` 已定义。`NewsListView` 有 `#if DEBUG` 调试铃铛（三连测试通知）。
- 可复用服务：`NewsCrawlService`（actor，`AsyncStream<CrawlEvent>`，防重入）、`DailyReportService`（actor）、`SourceRegistry`。

## 二、必须回答的调研问题（产出进 design.md）

1. **后台抓取**：Android `SourceCrawlWorker` 的周期/网络约束/重试/电池优化豁免逻辑；iOS 对应 `BGTaskScheduler`（`BGAppRefreshTaskRequest` earliestBeginDate 与 `newsCheckIntervalMinutes` 的映射）+ `BGProcessingTask` 取舍；**如实写明 iOS 调度不保证准点**（系统按使用习惯合并唤醒）的产品文案口径；App 前台时是否走应用内 Timer 补充（Android 语义对齐）。
2. **日报定时生成**：Android `DailyReportWorker` 触发时刻（`dailyReportTime` HH:mm）与补生成逻辑（错过当天怎么办）；iOS 无准点后台执行的替代——建议前台启动时检查「今天该生成未生成」补偿触发 + 后台任务尽力而为，写明语义差异。
3. **通知渠道与权限**：Android channel 设计（新闻/课程提醒各一？重要性级别）；iOS 对应 `UNNotificationCategory`/`UNNotificationContent`（线程 ID/深度点击动作）；权限申请时机（进入通知设置页开关时申请，非启动即弹）。
4. **课程提醒排程**：Android 提前量（上课前 X 分钟？可配？）、排程窗口（一次排多少天？）、重排触发点（改课/换表/重启/时间变更）；iOS 用 `UNCalendarNotificationTrigger` 一次注册 N 条（iOS 64 条 pending 上限的核算）还是按天滚动注册；`ReminderRescheduleReceiver`/`ReminderBootstrapper`（重启恢复）在 iOS 无对应概念（系统托管），标注裁剪理由。
5. **新闻通知内容**：`NewsNotifier` 聚合策略（N 条摘要成一条？带 count？）、去重（水位 id）、点击进详情 or 列表；iOS 沿用已实现的 DeepLink 链路，补 `destination=news` 与 `news_detail` 的构造对齐。
6. **WidgetKit 课程小组件**：Android `CourseWidget` 尺寸族（4×2/4×4？）、显示内容（今天 N 节课/下周概览？）、刷新策略（`CourseWidgetWorker` 周期 + `WidgetUpdateScheduler`）；iOS `WidgetKit` 对应 `TimelineProvider`（按节次时间线预生成当日 entry，无网络拉取——数据从 App Group 共享）；**App Group 容器**为新增基础设施（DB/UserDefaults 共享读写方案需设计：GRDB 库文件能否双进程读？建议 snapshot JSON 导出进 App Group 而非共享 DB，写明取舍）；`WidgetSettingsManager` 配置项对齐 `WidgetKit` 的 `@AppStorage`/intent 配置。
7. **Me 设置页**：`NotificationSettingsScreen` 与 `WidgetSettingsScreen` 字段逐项清单 → iOS `SettingsHomeView` 新增两个入口（型同 NewsDisplaySettingsView）；开关即时生效路径（对齐课表四开关 `reloadPrefs` 模式）。
8. **调试与验收口径**：BGTaskScheduler 模拟器验证手段（`e -l` launch 参数触发 ` SimulatorControl`？Xcode Debugger simulate payload）；WidgetKit 模拟器预览与真机差异；通知注册/点击深链端到端手验清单。

## 三、约束与纪律（承接全程）

- **约束**（project_memory）：原生组件 + Liquid Glass（iOS 26 `if #available`，18 回退 `ultraThinMaterial`）；功能不缺失（平台能力错位时在 spec 标注裁剪/替代理由）；on-device 分支；用户 GitHub 身份 citrus-dot；**本次范围不含** WebView 教务导入（另立 change）与拖拽恢复（挂起待办）。
- **流程**：立案四件套落盘 `openspec/changes/ios-platform-integration/`（名称可按调研结论调整，kebab-case）→ `openspec validate` 通过 → NotifyUser 提交评审 → **用户批准后才实施**。
- **实施节奏参考**：阶段 5/6 的 a/b 两批验收模式（如 7a=通知+后台任务，7b=Widget+设置页），在 tasks.md 中给出分组建议。
- **环境**：Xcode 26.6 / Tahoe 26.6.2 / 模拟器 iPhone 17（iOS 26.5）。

## 四、交付物

1. `openspec/changes/<name>/` 四件套：proposal.md（why/what/non-goals）、specs/<capability>/spec.md（ADDED/CHANGED/REMOVED delta，Requirement + WHEN/THEN Scenario）、design.md（逐条回答 §二 8 个调研问题，D-x 编号决策）、tasks.md（分组 checklist，可回溯 spec scenario）。
2. `openspec validate <name>` 通过。
3. NotifyUser 向用户提交评审——**不自行开工实施**。

## 五、快捷命令

```bash
cd /Users/orange/OpenJWC_4ios/Packages/OpenJWCCore
swift test --disable-sandbox --skip AllSourcesSmoke --skip ScriptAcceptance --skip LLMKeyAcceptance 2>&1 | grep "Test run with"
# 期望：✔ Test run with 98 tests in 19 suites passed（离线基线）

git -C /Users/orange/OpenJWC_4ios log --oneline -3    # 确认 HEAD ≥ 27817ef（阶段 6 归档）
npx openspec list                                      # 现无活跃 change
npx openspec new change ios-platform-integration --description "..." --goal "..."
npx openspec validate ios-platform-integration
```

## 六、接手事项（立案调研 agent）

1. 按序读前置材料 → 逐文件深读 Android 三模块真源（work/notification/widget）。
2. 逐条回答 §二 调研问题，答案进 design.md（D-x 编号；平台语义差异必须显式写产品口径）。
3. 产出四件套 → validate → NotifyUser 评审。
4. **红线**：不实施代码；不扩大范围（阶段 8 打磨项、WebView 导入不在本案）；iOS 能力弱于 Android 时不硬凑，写清裁剪理由交用户拍板。
