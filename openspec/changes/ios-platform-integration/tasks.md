# Tasks: ios-platform-integration

> 交付节奏（复制阶段 5/6 被认可的模式）：**7a = 组 1、3、5-8**（通知 + 后台任务）先验收；**7b = 组 2、4、9-12**（Widget + 小组件设置）再验收。组 13 归档收尾。各组标注对应 spec Requirement 与 design 决策号；`design.md` D-4/D-7 编号被 proposal 引用，保持不变。

## 1. core：抓取事件外传【7a】（spec：后台资讯抓取/新闻通知；design D-5）
- [x] 1.1 `NoticeBrief` 载荷（id/title/label）+ `CrawlEvent.newNotices(sourceId:notices:)` 枚举case
- [x] 1.2 `NewsCrawlService.crawlOne` 水位标记处（`NewsCrawlService.swift:158-163`）外传：非 baseline 且有 newIds 时 yield 对应新记录；水位语义不变（照常 markNotified）
- [x] 1.3 单测：baseline 首抓不发、新增发且照常标水位、`CrawlCoordinator` 前台消费忽略事件不影响交互语义

## 2. core：课表快照模型【7b】（spec：小组件数据管线；design D-7）
- [x] 2.1 `WidgetSnapshot` 模型（schemaVersion + 表元数据 + 节次起止分钟 + 全部课程含 color ARGB）+ JSON 编解码（读侧宽容：缺字段/未知版本 → 空态）（**7a 提前完成**：组 3 CourseReminderPlan 依赖快照输入，纯 Foundation 无 WidgetKit 依赖）
- [x] 2.2 原子写辅助（临时文件 + rename）+ 快照文件路径约定（App Group 容器 `timetable-snapshot.json`）（**7a 提前完成**，另含 DB 记录 → 快照转换供提醒排程复用）
- [x] 2.3 单测：编码→解码回环、宽容读三态（缺字段/未知版本/文件不存在）、原子写（**7a 提前完成**）
- [ ] 2.4 `WidgetImageProcessor.downsampleAndEncode(jpeg:maxDimension:quality:)` core 纯函数（ImageIO + CGImageDestination；产物 ≤ 数百 KB）+ 单测（尺寸上限/体积上限/JPEG 完整性）【红线 3】

## 3. core：课程提醒计划纯函数【7a】（spec：课程提醒通知；design D-4）
- [x] 3.1 `CourseReminderPlan`：输入课表快照 + now + 14 天窗口 → [计划(稳定 id, fireDate=上课时刻−10 分钟, name/timeText/classroom/teacher)]；weekRule 命中、过去/超窗跳过
- [x] 3.2 稳定 id = `course-<tableId>-<courseId>-<week>-<classStartMillis>` 派生（确定性，可前缀过滤全量取消）
- [x] 3.3 64 条截断保近端（按上课时刻排序取前 64）
- [x] 3.4 单测：提前量/窗口边界/weekRule/id 确定性/64 截断

## 4. core：小组件显示状态与时间线纯函数【7b】（spec：课程小组件/小组件时间线/小组件尺寸族；design D-6）
- [ ] 4.1 `WidgetDisplayState`：直译 `WidgetModels` 六分支（今天剩余过滤/刚结束保留至下节/17:00 与末课后切明天/明天无课「明天没有课」/今天无课/全部结束）；倒计时分钟 ceil 不为负；MAX_COURSES=2
- [ ] 4.2 `WidgetTimelineBuilder`：节次边界 entry（推进过滤与切日）+ 进行中课程分钟粒度 entry + 午夜后切日 entry；entry 时刻单调；`.atEnd` 刷新点
- [ ] 4.3 单测：六分支显示 + 时间线推进（边界/分钟/午夜/缺失快照回退空态）

## 5. app：通知基础设施【7a】（spec：新闻通知/通知权限申请；design D-3/D-5）
- [x] 5.1 `NotificationAuthorizer`：requestAuthorization([.alert, .sound])（仅设置页开关操作时调用）/ 状态查询 / openSettingsURLPath 跳转 / scenePhase 回前台刷新
- [x] 5.2 `NewsNotifier`：单条（title「新资讯」/body 资讯标题/dest=news_detail+news_id）与多条（title「有新资讯」/body「N 条新资讯」+首条标题/dest=news）；threadIdentifier="news"；identifier 前缀+时间戳；发送时通知开关判定
- [x] 5.3 点击路由核验：既有 `NotificationDelegate` → `AppRouter` 链路零新增（spec 场景「单条直达详情/多条进列表」手验覆盖）

## 6. app：课程提醒调度器【7a】（spec：课程提醒通知；design D-4）
- [x] 6.1 `CourseReminderScheduler.reschedule()`：`getPendingNotificationRequests` 前缀过滤全量取消 → `CourseReminderPlan` 逐条 `UNTimeIntervalNotificationTrigger` 注册（content 对齐 Android title/body 四段格式，dest=timetable）
- [x] 6.2 关闭开关 / 无课 / 权限被拒 → 清空本类待发
- [x] 6.3 接入触发链：App 启动 + `courseReminderEnabled` 变化 + 当前表/课程变化（对齐 `NavContainer.kt:227-236` 语义）

## 7. app：后台任务协调器【7a】（spec：后台资讯抓取/日报定时生成；design D-1/D-2/D-13）
- [x] 7.1 `OpenJWCApp.init` 注册两类 handler（`org.openjwc.newsrefresh` BGAppRefresh / `org.openjwc.dailyreport` BGProcessing requiresNetworkConnectivity、requiresExternalPower=false）；**注册闭包与 expirationHandler 闭包定义于 `nonisolated static` 上下文（不继承 @MainActor），闭包内只 `Task { @MainActor in ... }` 跳主线程、不触碰任何 @MainActor 状态含 Logger**（Swift 6 隔离红线 1）
- [x] 7.2 Info.plist：`BGTaskSchedulerPermittedIdentifiers` + `UIBackgroundModes: [fetch, processing]`
- [x] 7.3 资讯任务运行体：全量抓取（复用 `NewsCrawlService` 防重入闸）→ 收集 newNotices → 开关判定 → NewsNotifier → 续排；expirationHandler 取消 + 续排；无订阅/通知关闭 → cancel；**`submit` 三错误（.notPermitted/.tooManyPendingTaskRequests/.unavailable）静默吞记日志不崩溃**；**所有路径（成功/失败/异常/expiration）恰好一次 `setTaskCompleted(success:)`**
- [x] 7.4 日报任务运行体：昨日 `DailyReportService.generate(day:)` → 续排次日时刻；expiration 取消 + 续排；**所有路径 `setTaskCompleted` 恰好一次**
- [x] 7.5 前台补偿：bootstrap 检查「今日已过 dailyReportTime 且昨日非 COMPLETED」→ 前台生成（幂等由 generate 守卫）
- [x] 7.6 前台 Timer：scenePhase active 期间按 `newsCheckIntervalMinutes` 驱动抓取（共用防重入闸）
- [x] 7.7 `syncAll()`：设置五字段变化 → 两任务提交/取消 + 提醒重排（对齐 `MainActivity.kt:49-60`）
- [ ] 7.8 手验：后台强制触发（LLDB `_simulateLaunchForTaskWithIdentifier`）不崩溃、expiration 续排、force-quit 后重启恢复（**2026-09-24 实测：iOS 26.5 模拟器 BGTaskScheduler 不可用 Code=1，本项移真机验收（阶段 8 免签侧载一并执行），详见 research-production-notes.md §7.2**）

## 8. app：Me 通知设置页 + 日报设置分组【7a】（spec：通知设置页/日报设置分组/通知权限申请；design D-3/D-8）
- [x] 8.1 `SettingsHomeView` 增「通知」入口；`NotificationSettingsView`：新闻分组（开关 + 间隔 Picker 15/30/60/180/360，关时间隔置灰）+ 课程提醒开关 + 权限状态行（被拒「去系统设置」）
- [x] 8.2 开新闻通知：权限未决 → 弹窗；授予 → 开关生效 + 立即抓取一次；拒绝 → 开关回弹 + 引导行
- [x] 8.3 开关/间隔即时生效（写入 SettingsStore → 7.7 syncAll，对齐课表四开关 reloadPrefs 模式）
- [x] 8.4 `LlmSettingsView` 增日报分组：开关 + HH:mm DatePicker（默认 00:10，关闭时置灰），变更即同步日报任务（分组 UI 阶段 5 已备，本次接入 submitDailyReportTask 同步）

## 9. widget：target 基建【7b】（spec：课程小组件/小组件数据管线；design D-7/D-10）
- [ ] 9.1 `project.yml` 增 `OpenJWCWidget` appex target（依赖 OpenJWCCore、嵌入主 app、App Group entitlement 双侧开通）
- [ ] 9.2 `xcodegen generate` + 模拟器构建通过（App Group 模拟器免签验证）

## 10. widget：TimelineProvider + 三尺寸视图【7b】（spec：课程小组件/小组件时间线/小组件尺寸族；design D-6）
- [ ] 10.1 `CourseTimelineProvider`：读快照 JSON → `WidgetTimelineBuilder` → Timeline(.atEnd)；缺失/解码失败 → 空态 entry
- [ ] 10.2 Medium 基准布局：头部（icon + 今天/明天·星期 + 第 N 周）+ 最多 2 门课程卡（时间列 + 色条 + 课名 + 第 X-Y 节|教室|教师 + 约 N 分钟倒计时）；**`.containerBackground(for: .widget)` 必用（红线 2）；有背景图时 `containerBackgroundRemovable(false)`、无背景图时默认可移除；`.contentMarginsDisabled()` + 自管内边距；课程色条/倒计时可 `.widgetAccentable()`（可选增强）**
- [ ] 10.3 Small（头部 + 精简行）/ Large（Medium 同款 + 完整列表）两尺寸
- [ ] 10.4 `widgetURL` → 主 app `onOpenURL` → `AppRouter` 深链课表 tab
- [ ] 10.5 `WidgetSettingsReader`：group defaults 两键 + 背景图读取（路径缺文件回退纯色）

## 11. app：快照导出与触发链接线【7b】（spec：小组件数据管线；design D-7/D-8）
- [ ] 11.1 `WidgetSnapshotWriter.export()`：当前表 + 节次 + 课程 → `WidgetSnapshot` JSON 原子写 App Group → `WidgetCenter.shared.reloadTimelines`
- [ ] 11.2 接入触发链：bootstrap 首次导出 + `TimetableStore` 快照变化（table.id + courses.count，distinctUntilChanged 等价）→ export + reload
- [ ] 11.3 小组件设置变更（背景/不透明度/移除背景）→ group defaults 写入 + reload

## 12. app：Me 小组件设置页【7b】（spec：小组件设置页；design D-8）
- [ ] 12.1 `SettingsHomeView` 增「小组件」入口；`WidgetSettingsView`：静态示例预览（实时反映背景/不透明度）+ 选择图片（PhotosPicker → **降采样 ≤1280px + 重编码 JPEG quality≈0.75（红线 3，`WidgetImageProcessor` core 纯函数）**存 group 容器）+ 移除背景（红字，有背景时显示）+ 不透明度滑块（0-100% 显示 / 0...1 存储，默认 0.5）
- [ ] 12.2 任一变更写入 group defaults 并触发小组件刷新（11.3 链路）

## 13. 手验与归档
- [ ] 13.1 7a 手验（D-9 清单 ①-⑨）：权限弹窗/拒权引导、单条/多条通知点击深链、课程提醒 10 分钟横幅 + 点击、改课重排、关提醒清空、后台抓取（模拟器等待 + LLDB `_simulateLaunchForTaskWithIdentifier` 强制触发）、日报错过补偿 → 用户确认
- [ ] 13.2 7b 手验：三尺寸渲染、改课即时刷新、背景图/不透明度生效、分钟倒计时推进、17:00 后切明天、快照缺失空态 → 用户确认
- [ ] 13.3 全量测试绿（离线 98+新增；外网套件单跑）+ `xcodegen generate` + `xcodebuild` 模拟器构建通过
- [ ] 13.4 roadmap 更新（阶段 7 完成小节）+ `openspec archive ios-platform-integration -y` + commit/push（中文提交信息）
