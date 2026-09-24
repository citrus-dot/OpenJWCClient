# Proposal: ios-platform-integration

## Why
阶段 4/5/6 已完成归档（`27817ef`），五 tab 全部转正，离线 98/19 测试全绿。但 iOS 端仍是「纯前台应用」：退出即停止工作——不抓资讯、不生成日报、不发任何通知、桌面无小组件。Android 端的平台集成三模块（`work/` 后台任务、`notification/` 通知、`widget/` 课程小组件）承担了「不打开 App 也能用」的全部体验：后台按间隔抓新资讯并通知、上课前 10 分钟课程提醒、桌面一眼看今天剩什么课。不补齐此层，iOS 端无法达成 D10「功能不缺失」对照基准。

iOS 与 Android 存在**产品级平台语义差异**（BGTaskScheduler 不保证准点轮询、无 BOOT_COMPLETED 概念、WidgetKit 无主动刷新），本案按先例（阶段 6 拖拽挂起、WebView 裁剪）在 spec/design 中显式标注裁剪或替代方案及理由，交用户评审拍板。

## What Changes

### 1. 后台任务（对齐 `work/SourceCrawlWorker` + `DailyReportWorker` + `NewsNotificationScheduler`）
- **core 新增** `NewsCrawlService` 通知外传：抓取水位已落库（baseline/newIds `markNotified`），新增把 `newNotices` 随事件流外传（`CrawlEvent.newNotices`），前台交互抓取维持「视为已读」不变
- **app 新增** `BackgroundTaskCoordinator`：BGTaskScheduler 注册与提交（App init 时 register，前台提交/续排）：
  - 资讯抓取 `BGAppRefreshTask`（id `org.openjwc.newsrefresh`）：earliestBeginDate = `newsCheckIntervalMinutes`；运行 = 抓全部订阅源 → 新增条目发新闻通知 → 续排
  - 日报 `BGProcessingTask`（id `org.openjwc.dailyreport`）：requiresNetworkConnectivity；earliestBeginDate = 下一个 `dailyReportTime`；生成**昨日**日报（`DailyReportService.generate(day:)` 已就绪）
- **前台补偿**（iOS 语义差异的核心替代）：bootstrap 检查「今日已过 dailyReportTime 且昨日日报缺失」→ 前台补生成；App 前台期间资讯抓取由应用内 Timer 按间隔补充驱动（对齐 Android WorkManager 前台照跑语义）
- 前台 Timer 与后台任务共用 `NewsCrawlService` 防重入闸（isRunning）

### 2. 通知（对齐 `notification/` 8 文件）
- **app 新增** `NewsNotifier`：单条（title=通知「新资讯」/body=资讯标题，userInfo `destination=news_detail`+`news_id`）/ 多条（title=「有新资讯」/body=「N 条新资讯」+ 首条标题，`destination=news`）；`threadIdentifier` 分组（news / courseReminder）
- **app 新增** `CourseReminderScheduler`：读取当前课表快照 → 为未来窗口内每节课注册 `UNTimeIntervalNotificationTrigger` 通知（提前 10 分钟、content=课名·时间段·教室·教师、`destination=timetable`）；全量取消重排（`removeAllPendingNotificationRequests` 过滤本类前缀 id + 重注册）
- **权限**：进入通知设置页操作开关时 `requestAuthorization`（对齐 Android 非启动即弹）；被拒后开关行显示引导「去系统设置」
- **深链**：完全复用已实现链路（`NotificationDelegate` → `AppRouter.enqueueDeepLink` → `AppShellView.task(id:)`），零新增路由代码
- **裁剪**（spec 标注理由）：电池优化豁免、自启动引导 → iOS 无对应概念（后台调度系统托管）；`ReminderRescheduleReceiver` 的 BOOT_COMPLETED / MY_PACKAGE_REPLACED / TIME_SET / TIMEZONE_CHANGED 恢复 → iOS 通知由系统持久存储，重启/升级不丢（时间变更由前台重排覆盖）

### 3. WidgetKit 课程小组件（对齐 `widget/` 8 文件）
- **新增 target** `OpenJWCWidget`（appex）+ **App Group**（`group.org.openjwc.shared`）基础设施
- **数据管线（snapshot JSON 方案，不共享 DB）**：app 侧课表/设置变化时导出课表快照 JSON（表配置+节次+全部课程）写入 App Group 容器；widget 的 `TimelineProvider` 读取 JSON 本地计算显示状态（复刻 `WidgetModels.computeWidgetDisplayState` 语义：今天剩余/明天预告/17:00 后切明天/最多 2 门/节次边界）
- **Timeline 策略**：按节次边界 + 倒计时分钟粒度预生成当日 entries（`.atEnd` 刷新；午夜后一 entry 切新一天）；app 进程在课表变化/抓取完成后 `WidgetCenter.shared.reloadTimelines`
- **尺寸**：systemMedium（对齐 Android 4×2）+ systemSmall + systemLarge（iOS 递进增强）；Medium 布局对齐 Android（头部 icon+今天/明天·星期+第 N 周 → 最多 2 行课程卡：时间列+课程色条+课名+节次|教室|教师+「约 N 分钟」下课倒计时）
- **点击**：`widgetURL` → `onOpenURL` → `AppRouter` 深链课表 tab（复用路由）
- **小组件设置**：背景图 + 不透明度（对齐 `WidgetSettingsManager` 两项），存 App Group UserDefaults（widget 进程可读）

### 4. Me 设置页（对齐 `NotificationSettingsScreen` + `WidgetSettingsScreen` + LlmSettings 日报分组）
- `SettingsHomeView` 新增「通知」「小组件」两入口
- **通知设置页**：新闻通知开关（开时立即抓一次反馈）+ 检查间隔（15/30/60/180/360 分钟 Picker）+ 课程提醒开关 + 通知权限状态行；开关即时生效（写 `SettingsStore` + 触发对应调度器 sync，对齐课表四开关 reloadPrefs 模式）
- **小组件设置页**：预览（实时反映背景/透明度）+ 选择/移除背景图 + 不透明度滑块
- **LlmSettingsView 新增日报分组**（iOS 当前缺口）：日报开关 + 生成时间（HH:mm）

## 调研依据（2026-09-23，Android 真源逐文件 + iOS 资产核对）
- **Android 真源 21 文件全部通读**：`work/`（SourceCrawlWorker 周期=通知间隔或源最小 @schedule 下限 15 分钟/CONNECTED 约束/UPDATE 策略/异常 retry；DailyReportWorker 24h 周期+initialDelay 到 dailyReportTime/生成昨日/CONFIG_RELATED 不重试；NewsNotificationScheduler 门面）；`notification/`（NewsNotifier 单条直达详情/多条 InboxStyle 5 行摘要/固定 id 1001 覆盖式；CourseReminderScheduler AlarmManager 精确闹钟/提前 10 分钟固定/21 天窗口/requestCode 记账全量重排；重排触发=启动+设置变化+课表变化+四种系统广播）；`widget/`（Glance SizeMode.Exact/compact<166dp 双档；WidgetModels 显示状态算法：17:00 或末课后切明天/剩余课过滤/刚结束保留倒计时 0/下边界刷新；单闹钟滚动刷新+updatePeriodMillis 3h 兜底；背景图+透明度两项设置）；Me 两设置屏（权限三开关/新闻两字段/课程提醒开关/背景图+透明度+预览）
- **触发点链路核验**（`MainActivity.kt:50-70` + `NavContainer.kt:217-236` + `AndroidManifest.xml:41-53`）：设置五字段变化 → 三 scheduler sync；订阅集合变化 → 抓取重排；当前表+课程数变化 → 提醒重排+widget 刷新；BOOT/PACKAGE_REPLACED/TIME_SET/TIMEZONE_CHANGED → reschedule+refreshWidget
- **iOS 资产核验**：`UserSettings` 三字段 + dailyReportEnabled/Time **全部已备**（`SettingsStore.swift:56-63`，读写完整，与 Android 一一对应无缺口）；深链链路完整可复用（`OpenJWCApp.swift:45-77` delegate → `AppRouter.swift:40-59` → `AppShellView.swift:45-48`）；`NewsCrawlService` 水位已实现（baseline/newIds markNotified，`NewsCrawlService.swift:146-152`）但 newNotices 未外传——本案扩展点；`NoticeDao` 已有 `markNotified`/`selectNotifiedIds`；`DailyReportService.generate(day:)`/`statusOf(day:)` 就绪；`LlmSettingsView` 无日报分组（iOS UI 缺口）；widget 背景设置在 Android 为独立 SharedPreferences（非 UserSettings）——iOS 需新增存储
- **平台语义差异调研**：BGTaskScheduler（earliestBeginDate 为最早而非保证时刻；系统按电量/使用习惯合并唤醒；需 Info.plist `BGTaskSchedulerPermittedIdentifiers` + `UIBackgroundModes`；每次运行末须 re-schedule）；UNUserNotificationCenter pending 上限 64 条（21 天窗口典型课程量可能超限——见 design D-4 窗口核算）；WidgetKit 刷新受系统预算约束（约 40-70 次/天，不可依赖分钟级系统拉取——时间线预生成规避）；模拟器验证手段（`_simulateLaunchForTaskWithIdentifier` 私有 API 仅模拟器可用）

## Non-goals
- **WebView 教务导入** → 另立 change（阶段 6 决策延续）
- **拖拽调课恢复** → 挂起待办（`f1f597c` + TimetableStore TODO）
- Android `AddShortCut` 桌面快捷方式 → iOS 无对应概念，裁剪
- **电池优化豁免 / 自启动引导** → iOS 无对应概念（后台调度系统托管、无厂商自启动碎片化问题），裁剪（spec 标注）
- **锁屏/灵动岛 Live Activity**（下课倒计时实时刷新）→ iOS 增强方向，本案不含（时间线 entry 的静态倒计时已覆盖核心场景），阶段 8 或另案评估
- **Widget 交互式配置**（`AppIntent` 参数化：按表切换/显示天数选择）→ Android 端无对应配置（仅背景/透明度），对齐基线不含
- **iOS 通知扩展（Notification Service Extension）富媒体** → Android 端无对应，裁剪
- xcstrings 5 语言 / 三层图标 / Liquid Glass 全覆盖复查 / Dynamic Type → 阶段 8 打磨
- 深层动画定制（通知横幅自定义呈现）→ 系统接管，不在范围

## Impact
- **core**：`NewsCrawlService` 扩展 newNotices 外传（约 +40 行，含单测）；新增课表快照导出纯函数（JSON 编解码，约 100 行，单测锁定）——既有 98 测试必须保持绿，新增约 10-15 个
- **app**：新增 `Background/`（协调器）、`Notifications/`（两 notifier + 排程器）、设置两页 + LlmSettings 日报分组、`OpenJWCApp` BGTask 注册（约 10-14 文件）
- **新 target**：`OpenJWCWidget` appex（TimelineProvider + 三尺寸视图 + 快照读取，约 6-8 文件）+ project.yml target/App Group 配置 + 主 app `onOpenURL` 接线
- **基础设施**：App Group capability（模拟器免签可用；真机侧载需签名支持，阶段 8 免费签名侧载一并处理）
- **风险**：① BGTaskScheduler 模拟器验证依赖私有 API（真机行为不可完全复现，验收口径以模拟器+前台补偿为准）；② 64 条 pending 上限与排程窗口的核算需实现期实测（design D-4 已给保护策略）；③ App Group 数据迁移（user_settings suite 若改挂 App Group 需一次性搬移——design D-7 给了独立存储的替代方案）
- **测试基线**：`swift test --disable-sandbox --skip AllSourcesSmoke --skip ScriptAcceptance --skip LLMKeyAcceptance` 期望 98/19 → 全绿保持 + 新增
