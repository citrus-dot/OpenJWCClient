# Design: ios-platform-integration

> 调研基准（2026-09-23 立案会话逐文件通读 + 本会话复核行号）：Android 真源 `app/src/main/java/org/openjwc/client/{work,notification,widget}/` 19 文件 + Me 两设置屏 + 触发点链路（`MainActivity.kt:48-65`、`NavContainer.kt:217-236`）；iOS 资产核验（`SettingsStore.swift:40-73`、`NewsCrawlService.swift:144-163`、`OpenJWCApp.swift:43-77`、`AppRouter.swift:40-59`、`DailyReportService.swift:30-134`、`AppEnvironment.swift`）。本文按交接文档 §二 8 个调研问题逐条作答（D-1~D-9），D-10~D-12 为落点/测试/节奏。**D-4 与 D-7 的编号被 proposal.md 引用，不可变动。**

## D-1 后台资讯抓取（调研问题 1）

**Android 事实**（`SourceCrawlWorker.kt`）：
- 排程 `SourceCrawlScheduler.sync`（:103-134）：周期 =「通知开启 → `newsCheckIntervalMinutes`；关闭 → 订阅源最小 `@schedule`」，下限 15 分钟（:87）；`NetworkType.CONNECTED` 约束；`ExistingPeriodicWorkPolicy.UPDATE`（重复调用不重置周期）；**无订阅源 → cancel**。
- 运行 `doWork`（:33-76）：逐订阅源 `runner.crawl` → `settleNotifications(outcome, notify = newsNotificationEnabled)` → `toNotify` 非空则 `NewsNotifier.postNewNews`；异常 → `Result.retry()`（WorkManager 指数退避）。
- `runOnce`（:137-149）：OneTime + KEEP，开关打开时即时反馈用。

**iOS 决策**：`BGTaskScheduler` 单任务等价 + 前台 Timer 补充：

| Android 机制 | iOS 对应 | 说明 |
|---|---|---|
| `PeriodicWorkRequest` 周期 | `BGAppRefreshTaskRequest`（id `org.openjwc.newsrefresh`），`earliestBeginDate = newsCheckIntervalMinutes` | **语义差异**：earliest 是最早可能时刻，系统按电量/使用习惯合并唤醒，无准点保证——产品文案统一口径「后台任务由 iOS 系统统一调度，实际执行时间可能晚于设定值」（spec 头部已固化） |
| `NetworkType.CONNECTED` | BGAppRefresh 系统默认网络可用才跑 | 无需显式约束 |
| `Result.retry()` | **无等价**：BGTask 不自动重试 | 替代 = 每次运行结束（成功/失败/expired 皆同）重新 `submit`；抓取的中断安全由水位机制保证（中断源的新条目未标 notified，下轮照常作为新条目出现，不漏不重） |
| UPDATE 策略（不重置周期） | 重复 `submit` 同 id 请求即覆盖（iOS 天然幂等） | 设置变化时前台重提交 |
| 前台照跑 | `scenePhase == .active` 期间应用内 Timer 按同间隔驱动抓取 | 与后台任务/用户下拉共用 `NewsCrawlService` actor `isRunning` 防重入闸（`NewsCrawlService.swift:59-62`），任一在跑则本轮跳过 |
| 通知关闭时仍按源最小 @schedule 后台更新缓存 | **裁剪**：通知关闭 → `cancel(taskRequestWithIdentifier:)` | 理由：BGAppRefresh 系统预算稀缺（约每日几十次），无用户感知的后台缓存更新不值得耗预算；缓存新鲜度由前台 Timer（打开即抓）+ 下拉刷新兜底。spec 已按此口径书写，属显式平台裁剪非遗漏 |

**接线**：`BGTaskScheduler.shared.register` 必须在 App 启动完成前调用（`OpenJWCApp.init`，先于 `finishLaunching` 返回）；提交/续排在 `scenePhase` 活跃时。运行体 = 复用 `CrawlCoordinator`/`NewsCrawlService` 全量抓取 → 收集 `CrawlEvent.newNotices`（D-5 扩展点）→ 通知开关运行时判定 → `NewsNotifier` 发送 → 续排。`expirationHandler` = 取消抓取 Task（源间检查点生效）+ 续排。

## D-2 日报定时生成（调研问题 2）

**Android 事实**（`DailyReportWorker.kt`）：
- 排程 `DailyReportScheduler.sync`（:81-104）：`dailyReportEnabled` 关闭 → cancel；开启 → 24h 周期 + `setInitialDelay(millisUntilNext(dailyReportTime))`（:107-115，解析失败退化 1 小时）+ CONNECTED。
- 运行 `doWork`（:38-70）：生成**昨日**（`LocalDate.now().minusDays(1)`）；`CONFIG_RELATED`（缺 Key/Key 无效）→ `Result.failure()` 不重试（原因已落库页面可见）；其余失败 → `retry()`。

**iOS 决策**：`BGProcessingTask`（id `org.openjwc.dailyreport`，`requiresNetworkConnectivity = true`、**`requiresExternalPower = false`**——默认 true 会让「睡前充电才生成」变成硬约束，00:10 场景不成立）+ `earliestBeginDate = 下一个 dailyReportTime` + 运行体复用 `DailyReportService.generate(day:)`（`DailyReportService.swift:30`，头注释「阶段 7 的 BGTask 直接复用」即为此案预留；actor + 状态机落库已就绪）。每次运行末重排到次日同时刻。

**前台补偿（iOS 语义差异的核心替代）**：`AppEnvironment.bootstrap()` 增检查——今日已过 `dailyReportTime` 且昨日日报 `statusOf(day:)` 非 COMPLETED → 前台触发生成（进度在日报 tab 可见）。与 Android 的两处良性偏差：
1. WorkManager 24h 周期错过的执行 iOS 无补偿重试 → 前台补偿补位（下次打开 App 时补上）；
2. `CONFIG_RELATED` Android 当天放弃 → iOS 前台补偿会在下次启动再试一次（用户在场，重试成本低；COMPLETED 幂等守卫防重复，`generate` 对已完成直接返回）。

`expirationHandler`：LLM 长跑被系统截断 → cancel 生成 Task（AgentLoop 取消已验证）+ 续排；未完成状态由下次前台补偿接续。

## D-3 通知渠道与权限（调研问题 3）

**Android 事实**：
- 双渠道：`news_channel` IMPORTANCE_DEFAULT（`NewsNotifier.kt:32-38`）、`course_reminder` IMPORTANCE_HIGH（`CourseReminderReceiver.kt:72-79`）。
- 权限申请时机：**仅**在通知设置页操作时（`NotificationSettingsScreen.kt:101-115` launcher；「不再询问」被拒 → `openNotificationSettings` 引导）；`ON_RESUME` 从系统设置返回时刷新状态（:118-127）。

**iOS 决策**：
- 渠道 → `threadIdentifier` 分组（`"news"` / `"courseReminder"`）：iOS 无渠道概念，thread 是通知中心聚合呈现的等价物；`UNNotificationCategory` 不需要（无自定义动作按钮，Android 亦无）。
- 权限：`requestAuthorization([.alert, .sound])` 仅在设置页开关操作时调用（对齐时机，不启动即弹）；被拒后（`getNotificationSettings().authorizationStatus == .denied`）两开关置灰 + 「去系统设置」行（`UIApplication.openSettingsURLPath`）；设置页 `scenePhase` 回前台 / `onAppear` 时刷新权限状态（ON_RESUME 等价）。
- 裁剪（spec 已标注）：电池优化豁免、自启动引导两开关——iOS 后台调度完全系统托管，无厂商碎片化，无对应概念。

## D-4 课程提醒排程与 64 条 pending 核算（调研问题 4）

**Android 事实**（`CourseReminderScheduler.kt`）：
- 提前量 `REMINDER_LEAD_MILLIS = 10 分钟` 固定不可配（:154）；窗口 `SCHEDULE_WINDOW_MILLIS = 21 天`（:156）。
- 排程（:23-90）：全量取消 → 权限检查 → 遍历 `week 1..totalWeeks × courses`（weekRule 命中 + 节次起时刻可解析），`reminderMillis ∈ (now, now+21天]` 才注册；精确闹钟（`setExactAndAllowWhileIdle`，S+ 无权限退化 `setAndAllowWhileIdle`）。
- requestCode = `"$tableId|$courseId|$week|$classStartMillis".hashCode() and 0x7fffffff`（:111-116），集合存 SharedPreferences 供全量取消（:87-108）。
- 内容（`CourseReminderReceiver.kt:42-58`）：title「课程还有 10 分钟开始」+ body `%name · %time · %classroom · %teacher`（`strings.xml:558`），dest=timetable。
- 重排触发：App 启动（`MainActivity.kt:49-60`）、`courseReminderEnabled` 变化（同链）、当前表/课程变化（`NavContainer.kt:227-236` combine(table.id, courses.size) distinctUntilChanged）；系统广播 BOOT_COMPLETED / MY_PACKAGE_REPLACED / TIME_SET / TIMEZONE_CHANGED（`ReminderRescheduleReceiver`）。

**iOS 决策**：`UNTimeIntervalNotificationTrigger`（interval = 提醒时刻 − now，每次全量重排时重算）。**64 条 pending 上限核算**（iOS 系统硬限制，超出丢弃最旧）：

| 窗口 | 典型课表（≤25 节/周） | 极限课表（30 节/周） | 结论 |
|---|---|---|---|
| 21 天（Android 原值） | 75 条 | 90 条 | 均溢出 ✗ |
| **14 天（采用）** | 50 条 | 60 条 | ≤64 ✓（贴上限，留 4 余量） |
| 7 天 | 25 条 | 30 条 | 安全但收益低（重排本就每次启动全量做，窗口滚动自动前移） |

超 64 条时**保近端**（按上课时刻排序取前 64，远端课程靠下次启动滚动重排补入）。稳定 id = `course-<tableId>-<courseId>-<week>-<classStartMillis>` 派生（对齐 Android requestCode 语义，确定性派生使全量取消可按前缀 `course-` 过滤，无需 SharedPreferences 记账——`removePendingNotificationRequests(withIdentifiers:)` 按已注册 id 列表或 `getPendingNotificationRequests` 过滤前缀）。计划生成为 core 纯函数 `CourseReminderPlan`（输入快照 + now + 窗口 → [计划(id, fireDate, 内容字段)]），app 层只做注册，64 截断可单测。

**裁剪**（spec 已标注）：`ReminderRescheduleReceiver` 四广播——iOS 本地通知系统持久存储，重启/升级待发不丢；时间/时区变更由「每次启动全量重排」覆盖（iOS 无此类广播，App 前台即重排时机）。

## D-5 新闻通知内容构造（调研问题 5）

**Android 事实**（`NewsNotifier.kt`）：单条 → title=资讯标题、text=资讯标签（:80-92），dest=news_detail+id；多条 → InboxStyle 最多 5 行标题 + 「还有 N 条」摘要（:94-117），title=「新资讯」类摘要标题、text=N 条计数、`number=N`，dest=news；**固定 id 1001 覆盖式**（:74，新通知顶掉旧通知）；canPostNotifications 前置检查 + SecurityException 吞掉（竞态容忍）。

**iOS 决策**（spec 口径 + 两处显式偏差）：
- 单条：title=「新资讯」、body=资讯标题（iOS 横幅上 App 名常驻，Android 用资讯标题当 title 的信息结构在 iOS 语境下倒置更自然）；userInfo `destination=news_detail` + `news_id`。
- 多条：title=「有新资讯」、body=「N 条新资讯」+ 首条标题（**偏差**：InboxStyle 无逐行等价 API，替代为计数摘要 + `threadIdentifier=news` 系统堆叠分组，spec 已记录）。
- identifier = 前缀 + 时间戳（**偏差**：Android 固定 id 覆盖式 vs iOS 保留未读历史——iOS 通知中心自带按 thread 聚合，不依赖覆盖；spec 已记录）。
- 点击路由零新增：`NotificationDelegate`（`OpenJWCApp.swift:55-66`）读 `destination`/`news_id` → `AppRouter.handleDeepLink`（`AppRouter.swift:46-59`，news_detail 无效 id 由视图层查库降级——阶段 4 已锁定）。

**core 扩展点**：`CrawlEvent` 增 `case newNotices(sourceId: String, notices: [NoticeBrief])`——`crawlOne` 在非 baseline 且有 newIds 时 yield（`NewsCrawlService.swift:158-163` 现有水位标记处顺带外传记录摘要 id/title/label）；水位语义不变（照常 `markNotified`），前台交互抓取消费者忽略此事件（「视为已读」不变），后台任务消费者聚合后交 `NewsNotifier`。通知开关在**发送时**判定（对齐 Android `settleNotifications(notify:)` 运行时读设置）。

## D-6 WidgetKit 课程小组件：显示算法与时间线（调研问题 6 前半）

**Android 事实**：
- 显示状态（`WidgetModels.kt:52-121`）：`forecastMinute = max(17:00, 今日末课结束)`，`current ≥ forecastMinute` → 切明天；今天模式剩余过滤 = `endMinute > current || start == latestStartedMinute`（**刚结束的课保留倒计时 0 至下节开始**，:92-97）；`MAX_COURSES = 2`；`nextRefreshAtMillis` = 下一个节次边界，进行中有课时压缩到分钟粒度（:107-112）；午夜后 00:05 切日（:174-177）；倒计时 = 剩余分钟**向上取整**且不为负（:180-184）。
- 刷新链：`WidgetDataManager.refreshWidgetAndWait` = 算状态 → `WidgetUpdateScheduler.scheduleRefresh(nextRefreshAtMillis)`（**单闹钟滚动**，`WidgetUpdateScheduler.kt:41-58`）→ `updateAll`；`CourseWidgetWorker`（WorkManager one-shot）承接闹钟触发；`provideGlance` 每次渲染也重排闹钟（`CourseWidget.kt:22`）。
- 布局（`CourseWidget.kt` + `ui/WidgetLayouts.kt`）：`SizeMode.Exact`（compact < 166dp 双档）；头部 = App 图标 + 「今天/明天 · 星期X」 + 「第 N 周」；课程卡 = 起止时间列 + 色条 + 课名 + 「第 X-Y 节 | 教室 | 教师」 + 「约 N 分钟」倒计时；文案 `strings.xml:561-568`。
- 设置（`WidgetSettingsManager.kt`）：背景图路径 + 不透明度（0..255 默认 128），独立 SharedPreferences（非 user_settings）。

**iOS 决策**：`TimelineProvider` 预生成时间线（无网络、纯本地快照计算）：

| Android 机制 | iOS 对应 |
|---|---|
| 单闹钟滚动刷新 + 分钟级倒计时 | 时间线 entry 预生成：每个节次边界（课程起/止时刻）一个 entry（推进剩余过滤与切日判定）；进行中课程覆盖时段**每分钟一个 entry**（倒计时分钟推进的等价物）；午夜后一 entry 切新一天；`.atEnd` 刷新 |
| `updatePeriodMillis` 3h 兜底 | `.atEnd` + app 侧 `WidgetCenter.shared.reloadTimelines`（课表/设置变化时） |
| 闹钟主动算状态 | 预计算「未来的显示状态」交给系统；系统刷新预算（约 40-70 次/天）只影响 timeline **重载**，不影响已交付 entry 展示——分钟级倒计时不受预算约束 |

显示状态算法**逐条直译** core 纯函数（`WidgetDisplayState`，输入快照+时刻），语义表对齐 spec 六场景。**一处显式修正**（spec 已按修正口径书写）：Android 明天无课时 `isDayComplete=true` 显示「今日课程已结束」（`CourseWidget.kt:43-45` × `WidgetModels.kt:83` 的组合歧义，语义错位）→ iOS 明天无课显示「明天没有课」。

**尺寸族**：systemMedium 为基准（对齐 Android 4×2 内容结构）；systemSmall（头部 + 精简行）/ systemLarge（Medium 同款 + 完整列表）为 iOS 递进增强。**偏差**：Android `SizeMode.Exact` 按 resize 连续自适应（compact/regular 双档），iOS 固定 family 三档离散布局，语义等价（尺寸自适应）。

## D-7 App Group 数据共享与存储布局（调研问题 6 后半，proposal 风险 ③ 引用）

**决策：snapshot JSON，不共享 DB**（对齐 handoff 建议，候选对比）：

| 维度 | a. 共享 GRDB 库文件（App Group 容器） | b. snapshot JSON 导出（**采用**） |
|---|---|---|
| 正确性 | WAL 双进程读写可行，但需协调连接池/迁移锁/文件锁，小组件进程崩在写事务会污染库 | 单写（主 app）多读（widget），原子写（临时文件 + rename），读侧宽容解码 |
| 数据量 | 全量 DB（含资讯/日报等 widget 不需要的大表） | 当前表 + 节次 + 课程，≤ 数 KB |
| 失败面 | 迁移期双进程版本不一致风险 | 快照缺字段/版本不识别 → 回退空态，不崩溃 |
| 开发成本 | 高（AppEnvironment 数据库路径改造 + 双进程测试） | 低（一个导出纯函数 + 一个读函数） |

**存储布局**（App Group `group.org.openjwc.shared`）：
- `timetable-snapshot.json`：`schemaVersion` + 表元数据（id/name/startDate/totalWeeks/节次起止分钟表）+ 全部课程（id/name/day/startPeriod/endPeriod/weekRule/location/teacher/color ARGB）。写入时机：表切换/课程增删改/导入/学期配置变化。原子写 + 版本号，widget 侧解码失败回退空态。
- 背景图文件 + UserDefaults（group suite）两键：`widget.backgroundPath`（相对容器路径）/ `widget.backgroundOpacity`（0...1 Double，默认 0.5 = Android 128/255 换算）。
- **`user_settings` 不迁移**（proposal 风险 ③ 的解法）：widget 只需要上述两键，把 `SettingsStore` 整体改挂 App Group suite 需一次性搬移全部设置且引入双进程写风险，收益为零——独立存储，主 app 写小组件设置时**双写**（本地无状态 + group suite），读取只走 group suite。
- **widget target 依赖 `OpenJWCCore` 本地包**（快照模型/显示计算/时间线 builder 均在 core，单测进 98 基线）：GRDB/SwiftSoup 随包链接但 widget 不触达，Swift 全模块优化死代码剔除，体积与内存影响可忽略；备选「拆独立 WidgetShared 小模块」被否（模块手术成本 > 收益，阶段 8 打磨期再评估）。

## D-8 Me 设置页与触发链（调研问题 7）

**Android 事实**（字段清单）：
- `NotificationSettingsScreen.kt`：①系统权限分组 = 通知权限开关（granted→跳系统设置；未决→弹窗；拒后不再弹→跳设置）+ 电池优化 + 自启动（:145-195）；②新闻通知 = 开关（依赖权限，开时 `runOnce` 即时反馈）+ 间隔 Dropdown 15/30/60/180/360 分钟（依赖开关，:197-235）；③课程提醒 = 开关（依赖权限，:237-250）。
- `WidgetSettingsScreen.kt`：静态示例预览（周四/第 13 周/两门示例课）+ 选图（GetContent → `filesDir/widget_background.jpg`）+ 移除背景（红字，仅有背景时显示）+ 不透明度滑块（0-100% 显示，0-255 存储，默认 128，拖动即存、抬手刷新）。
- 触发链：`MainActivity.kt:49-60` 设置五字段（newsNotificationEnabled/newsCheckIntervalMinutes/courseReminderEnabled/dailyReportEnabled/dailyReportTime）变化 → 三 scheduler sync；`NavContainer.kt:217-236` 订阅集合变化 → 抓取重排、当前表+课程数变化 → 提醒重排 + widget 刷新。

**iOS 决策**：
- `SettingsHomeView` 增「通知」「小组件」两入口（型同 `NewsDisplaySettingsView`）。
- `NotificationSettingsView`：新闻分组（开关 + 间隔 Picker 五档，开关关闭时间隔置灰）+ 课程提醒分组（开关）+ 权限状态行（被拒时「去系统设置」）；裁剪系统权限分组的电池优化/自启动（D-3）。开关开启且权限未决 → `requestAuthorization`；授予 → 立即抓一次（`runOnce` 等价 = 前台直接驱动一次 `CrawlCoordinator` 抓取）。
- `WidgetSettingsView`：预览（静态示例数据 + 所选背景/不透明度实时反映）+ 选图（`PhotosPicker`，写 group 容器）+ 移除（红字条件显示）+ 滑块（0-100% 显示、0...1 存 group defaults、变更即写 + 抬手 `reloadTimelines`）。
- `LlmSettingsView` 增「日报」分组（iOS 当前唯一缺口）：开关 + 时间（`DatePicker` HH:mm，默认 00:10），关闭时时间置灰。
- **触发链等价表**（对齐 Android 四链）：

| Android 触发 | iOS 等价 |
|---|---|
| MainActivity 五字段 → 三 sync | `AppShellView` 观察 `userSettings` 五字段（`.onChange`，distinct 等价）→ `BackgroundTaskCoordinator.syncAll()`（两类 BGTask 提交/取消）+ `CourseReminderScheduler.reschedule()` |
| NavContainer 订阅集合 → 抓取重排 | `NewsStore`/`ReactiveStore` 订阅集合变化 → `syncNewsTask()`（无订阅 → 取消 BGAppRefresh） |
| NavContainer (table.id, courses.size) → 提醒重排 + widget 刷新 | `TimetableStore` 快照同键变化 → 提醒全量重排 + `WidgetSnapshotWriter.export()` + `WidgetCenter.reloadTimelines` |
| 四系统广播 → 重排 + 刷新 | 裁剪（D-4：系统持久存储 + 启动全量重排覆盖） |
| MainActivity 启动 → scheduleMidnightRefresh | 不需要：时间线 `.atEnd` + 午夜 entry 自动切日 |

## D-9 调试与验收口径（调研问题 8）

- **BGTaskScheduler（模拟器）**：模拟器对 earliestBeginDate 大幅压缩（分钟级即触发），可「提交后等待」直接观测；强制触发用 LLDB 私有 API `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"org.openjwc.newsrefresh"]`（同族 `_simulateExpirationForTaskWithIdentifier:` 验证 expiration 续排；仅调试器可用）。**验收口径**：模拟器 + 强制触发 + 前台补偿为主，真机准点性**不做验收项**（产品文案已声明尽力而为——D-1 语义差异口径）。
- **WidgetKit**：模拟器桌面长按添加三尺寸实测；`xcodebuild` 构建 appex 通过为硬门槛；时间线推进用「改系统时间/等分钟边界 + `reloadTimelines`」观测；深色模式切换验证（对齐 D-8 深色纪律）。
- **通知端到端手验清单**：①设置页开新闻通知 → 权限弹窗 → 授予 → 立即抓取反馈；②拒权 → 开关回弹 + 引导行 → 去系统设置开启 → 返回页面状态刷新；③单条新资讯通知 → 点击 → 资讯 tab + 该条详情；④多条 → 点击 → 资讯列表；⑤课程提醒（注册测试课 10 分钟后开始）→ 提前 10 分钟横幅 → 点击 → 课表 tab；⑥改课 → 旧提醒不再触发（pending 列表核对）；⑦关课程提醒 → pending 清空；⑧日报：设 1 分钟后时刻 → 模拟器等待/强制触发 → 昨日日报生成；⑨错过时刻（改系统时间）→ 启动 App → 前台补偿生成。
- 基线命令沿用 handoff §五（swift test 离线 98/19 全绿保持 + 新增；`xcodegen generate` + `xcodebuild` 模拟器构建）。

## D-10 文件落点与组合根接线

```
Packages/OpenJWCCore/Sources/OpenJWCCore/
├── NewsCrawl/NewsCrawlService.swift        # 修改：CrawlEvent 增 newNotices(NoticeBrief)；crawlOne 水位处外传
├── Widget/WidgetSnapshot.swift             # 快照模型 + JSON 编解码（宽容读）+ 原子写辅助
├── Widget/WidgetDisplayState.swift         # 显示状态纯函数（直译 WidgetModels：17:00/末课切换、刚结束保留、MAX 2、倒计时 ceil）
├── Widget/WidgetTimelineBuilder.swift      # 时间线 entry 生成纯函数（节次边界/分钟倒计时/午夜 entry/.atEnd）
└── Widget/CourseReminderPlan.swift         # 提醒计划纯函数（10 分钟提前、14 天窗口、稳定 id、64 截断保近端）

ios/OpenJWC/
├── App/OpenJWCApp.swift                    # 修改：init 注册 BGTask handler；scenePhase 接 Timer
├── App/AppEnvironment.swift                # 修改：装配三协调器；bootstrap 增补偿检查/全量 sync/快照导出
├── App/BackgroundTaskCoordinator.swift     # 两类 BGTask 提交/取消/续排 + 前台 Timer + runOnce
├── Notifications/NewsNotifier.swift        # 单条/多条构造（threadIdentifier=news）+ 发送时开关判定
├── Notifications/CourseReminderScheduler.swift  # CourseReminderPlan → UNNotification 注册/前缀过滤全量取消
├── Notifications/NotificationAuthorizer.swift   # 权限申请/状态查询/系统设置跳转
├── WidgetSupport/WidgetSnapshotWriter.swift     # TimetableStore 快照 → JSON 导出 + reloadTimelines
└── Features/Me/Settings/
    ├── NotificationSettingsView.swift      # 两分组 + 权限行
    ├── WidgetSettingsView.swift            # 预览 + 背景图 + 不透明度
    └── LlmSettingsView.swift               # 修改：增日报分组

ios/OpenJWCWidget/                          # 新 appex target（project.yml：type app-extension、依赖 OpenJWCCore、
├── OpenJWCWidgetBundle.swift               #   App Group entitlement（主 app 同步开通）、嵌入主 app）
├── CourseTimelineProvider.swift            # 读快照 JSON + WidgetTimelineBuilder → Timeline(.atEnd)
├── CourseWidgetViews.swift                 # 三尺寸视图（Medium 基准布局/Small 精简/Large 全列表）
└── WidgetSettingsReader.swift              # group defaults + 背景图读取
```

project.yml 增量：`OpenJWCWidget` target；主 app Info.plist 增 `BGTaskSchedulerPermittedIdentifiers: [org.openjwc.newsrefresh, org.openjwc.dailyreport]` + `UIBackgroundModes: [fetch, processing]`；两 target 共享 App Group entitlement（模拟器免签可用，真机侧载留阶段 8 免费签名处理）。

## D-11 测试策略

| 层 | 用例族 | 数量级 |
|---|---|---|
| core 单测 | `CrawlEvent.newNotices`：baseline 首抓不发、新增条目发且照常标水位、前台消费忽略不影响交互语义 | 2-3 |
| core 单测 | `WidgetSnapshot`：编码→解码回环、宽容读（缺字段/未知版本→空态）、原子写 | 3-4 |
| core 单测 | `WidgetDisplayState`：今天剩余过滤/刚结束保留/17:00 与末课后切明天/明天无课/无课/全部结束/倒计时 ceil 不为负（直译 WidgetModels 六分支） | 6-8 |
| core 单测 | `WidgetTimelineBuilder`：节次边界 entry/分钟倒计时 entry 逐分钟推进/午夜切日 entry/entry 时刻单调/快照缺失回退 | 4-6 |
| core 单测 | `CourseReminderPlan`：10 分钟提前、窗口内过滤（过去/超窗跳过）、稳定 id 确定性、64 截断保近端、weekRule 命中 | 5-7 |
| app 手验 | D-9 清单 ①-⑨（7a 一批）+ 小组件三尺寸/改课刷新/背景设置/时间线推进（7b 一批） | 两批 |

既有 98 测试全绿保持为每组合并门槛。

## D-12 实施节奏（复制阶段 5/6 的 a/b 两批验收模式）

- **7a = 通知 + 后台任务**（组 1 + 3 + 5-8 + 手验）：core newNotices/CourseReminderPlan → NewsNotifier + 权限 + CourseReminderScheduler → BackgroundTaskCoordinator（两 BGTask + 前台 Timer + 日报补偿）→ 通知设置页 + LlmSettings 日报分组 → 触发链（设置/订阅/课表变化）。验收点：新闻通知点击深链端到端、课程提醒 10 分钟横幅、后台抓取（模拟器等待/强制触发）、错过日报前台补偿。
- **7b = Widget + 小组件设置**（组 2 + 4 + 9-12 + 手验）：core 快照/显示状态/时间线 → widget target 基建 → 三尺寸视图 + TimelineProvider → 快照导出接线（TimetableStore 变化 → export + reload）→ 小组件设置页。验收点：三尺寸渲染、改课即时刷新、背景图/不透明度生效、分钟倒计时推进、切明天。
- 组 13 归档收尾（全量测试 + xcodebuild + roadmap 更新 + archive）。
