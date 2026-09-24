# platform-integration Specification（delta）

> 行为契约以 Android 真源为准（`app/src/main/java/org/openjwc/client/{work,notification,widget}/` 及 Me 设置两屏），以下为 iOS 端对齐口径。平台能力错位处**显式标注裁剪/替代理由**（对齐阶段 6 拖拽挂起与 WebView 裁剪先例）。iOS 后台调度语义差异的产品文案口径统一为：**「后台任务由 iOS 系统统一调度，实际执行时间可能晚于设定值」**——所有涉及后台时序的用户可见文案 SHALL 采用此口径，不承诺准点。

## ADDED Requirements

### Requirement: 后台资讯抓取
App SHALL 在存在已订阅数据源且新闻通知开启时，通过 `BGTaskScheduler`（`BGAppRefreshTaskRequest`，identifier `org.openjwc.newsrefresh`）周期性后台抓取全部订阅源：请求的 `earliestBeginDate` = `newsCheckIntervalMinutes` 分钟（设置项 15/30/60/180/360）。每次任务运行 SHALL：执行抓取（复用 `NewsCrawlService` 防重入闸）→ 对新增条目（水位语义：非 baseline 抓取的新插入且未通知条目）发送新闻通知（通知开关关闭时仅更新缓存不发通知，对齐 Android `settleNotifications(notify:)`）→ 任务结束时重新提交下一次请求。无订阅源或通知关闭时 SHALL 取消该后台任务；设置变化时在前台重新提交。App 前台期间 SHALL 以应用内 Timer 按同一间隔补充驱动抓取（对齐 Android WorkManager 前台照跑语义），与后台任务共用防重入闸。
**平台语义差异（产品口径）**：iOS `BGTaskScheduler` 的 `earliestBeginDate` 是最早可能时刻而非保证时刻，系统按电量与使用习惯合并唤醒——实际间隔可能大于设定值，用户可见文案（设置页描述）SHALL 如实说明，不承诺准 15 分钟级轮询。

#### Scenario: 后台抓取发现新资讯并发通知
- **WHEN** 后台任务运行、抓取产生 3 条新增条目且通知开关开启
- **THEN** 3 条水位标记为已通知并发送新闻通知，任务结束时重新提交下一次后台请求

#### Scenario: 通知关闭时仅更新缓存
- **WHEN** 新闻通知开关关闭而后台抓取运行
- **THEN** 新增条目照常落库与标记水位，但不发送任何系统通知

#### Scenario: 前台间隔补充
- **WHEN** App 在前台停留超过 `newsCheckIntervalMinutes` 且有订阅源
- **THEN** 应用内 Timer 触发一次抓取；若后台任务或用户下拉正在抓取则跳过（防重入）

### Requirement: 日报定时生成
App SHALL 在日报开启（`dailyReportEnabled`）时，通过 `BGTaskScheduler`（`BGProcessingTaskRequest`，identifier `org.openjwc.dailyreport`，`requiresNetworkConnectivity = true`）尽力在每日 `dailyReportTime`（HH:mm）后台生成**昨日**日报（复用 `DailyReportService.generate(day:)`；配置类失败如缺 Key 不重试，原因已落库页面可见——对齐 Android `DailyReportWorker` 的 CONFIG_RELATED 分支）。因 iOS 不保证准点后台执行，App SHALL 在**前台启动时补偿检查**：今日已过 `dailyReportTime` 且昨日日报缺失（状态非 COMPLETED）→ 前台补触发生成。日报关闭时 SHALL 取消该后台任务。既有手动生成入口（日报 tab）保持不变。
**平台语义差异（产品口径）**：后台尽力而为 + 前台补偿是 Android 24h 周期定时任务的 iOS 替代——错过设定时刻的日报在下次打开 App 时补上，文案 SHALL 说明此语义。

#### Scenario: 前台补偿生成
- **WHEN** 用户在 14:00 打开 App、日报设定时间为 00:10 且昨日日报不存在
- **THEN** App 前台触发昨日日报生成（进度在日报页可见）

#### Scenario: 已生成不重复
- **WHEN** 昨日日报已存在（COMPLETED）且 App 启动
- **THEN** 不触发重复生成（`statusOf(day:)` 判定）

### Requirement: 新闻通知
新闻通知 SHALL 使用 `UNMutableNotificationContent`（`threadIdentifier = "news"` 分组）：单条新资讯时 title = 「新资讯」、body = 资讯标题、userInfo 携带 `destination = "news_detail"` 与 `news_id`；多条时 title = 「有新资讯」、body = 「N 条新资讯」+ 首条标题摘要、userInfo 携带 `destination = "news"`。通知 identifier 使用固定前缀 + 时间戳（新通知不覆盖未读旧通知——与 Android 固定 id 1001 覆盖式的差异：iOS 无 InboxStyle 聚合等价物，改用系统通知分组呈现，spec 记录此偏差）。点击通知 SHALL 经既有深链链路（`NotificationDelegate` → `AppRouter`）直达对应页面。
**Android 对照偏差说明**：多条摘要的 InboxStyle（5 行标题列表 + 「还有 N 条」）在 iOS 无逐行等价 API，替代为 body 文本计数摘要 + 系统通知堆叠分组。

#### Scenario: 单条直达详情
- **WHEN** 一次抓取新增 1 条资讯并通知、用户点击该通知
- **THEN** App 切到资讯 tab 并打开该条详情（无效 id 降级为列表，复用既有校验）

#### Scenario: 多条进列表
- **WHEN** 一次抓取新增 ≥2 条资讯并通知、用户点击通知
- **THEN** App 切到资讯 tab 列表页

### Requirement: 课程提醒通知
课程提醒开启（`courseReminderEnabled`）且通知权限已授予时，App SHALL 为当前课表未来窗口内的每节课注册提前 **10 分钟**（固定提前量，对齐 Android `REMINDER_LEAD_MILLIS`，不可配）的本地通知（`UNTimeIntervalNotificationTrigger`）：内容 title = 「课程还有 10 分钟开始」、body = 「课名 · 时间段 · 教室 · 教师」（空字段省略对应段）、userInfo `destination = "timetable"`，每条通知以稳定 id（表 id + 课程 id + 周 + 上课时刻派生）标识。排程窗口 SHALL ≤ 14 天（对齐 Android 21 天窗口的收缩：iOS 待发通知 64 条上限——按典型课表 2 周 × 每周 ≤ 30 节 = 60 条贴上限，窗口再大将溢出；超出 64 条时优先保留近端课程）。重排 SHALL 全量取消本类通知后重新注册，触发时机对齐 Android：App 启动、`courseReminderEnabled` 变化、当前课表或课程变化（表切换/课程增删改/导入）。开关关闭时 SHALL 清空全部待发课程提醒。
**平台裁剪说明**：Android `ReminderRescheduleReceiver`（BOOT_COMPLETED / MY_PACKAGE_REPLACED / TIME_SET / TIMEZONE_CHANGED 广播恢复）在 iOS 无对应概念——iOS 本地通知由系统持久存储，设备重启与应用升级后待发通知不丢失，裁剪该接收器；系统时间/时区变更语义由下次前台重排覆盖（iOS 无此类系统广播）。

#### Scenario: 提前十分钟提醒
- **WHEN** 某课程 08:00 开始上课且已注册提醒
- **THEN** 07:50 发出该课程通知，点击经深链进入课表 tab

#### Scenario: 改课后重排
- **WHEN** 用户修改一门课程的节次
- **THEN** 全部待发课程提醒取消并按新课表重新注册（旧时刻提醒不再触发）

#### Scenario: 64 条上限保护
- **WHEN** 14 天窗口内课程数超过 64 节
- **THEN** 仅注册最近 64 节（远端课程不注册，待滚动重排补入）

### Requirement: 通知权限申请
通知权限 SHALL 在用户于通知设置页操作开关时申请（`requestAuthorization([.alert, .sound])`），不在启动时主动弹出（对齐 Android 设置页时机）。权限被拒后：新闻通知与课程提醒开关 SHALL 显示为不可用或置灰并附「去系统设置」引导（跳转 App 通知系统设置页）；设置页从系统设置返回时 SHALL 刷新权限状态。
**平台裁剪说明**：Android 通知设置页的「电池优化豁免」「自启动」两开关在 iOS 无对应概念（后台调度完全系统托管、无厂商碎片化），裁剪并在 spec 记录。

#### Scenario: 开关触发权限弹窗
- **WHEN** 通知权限未决（未请求过）且用户首次打开新闻通知开关
- **THEN** 系统权限弹窗出现；授予则开关生效并立即抓取一次（对齐 Android `runOnce` 即时反馈），拒绝则开关回弹并显示引导

#### Scenario: 权限被拒后引导
- **WHEN** 用户曾拒绝权限并再次尝试开启
- **THEN** 不再弹系统弹窗，显示「去系统设置」引导行

### Requirement: 课程小组件（systemMedium）
SHALL 提供 WidgetKit 课程小组件（`OpenJWCWidget` extension，App Group `group.org.openjwc.shared`）：systemMedium 布局对齐 Android 4×2——头部（App 图标 + 「今天/明天 · 星期」 + 右侧「第 N 周」）+ 最多 2 门课程卡片（左侧起止时间列 + 课程色竖条 + 课程名 + 「第 X-Y 节 | 教室 | 教师」元数据行 + 进行中课程显示「约 N 分钟」下课倒计时，N 为向上取整剩余分钟）。显示状态语义直译 Android `WidgetModels`：当前时刻 ≥ max(17:00, 今日末课结束) 时切换为明天预告（明天无课显示「明天没有课」）；今天剩余课程过滤已结束课程、刚结束课程保留至下节课开始；无课显示「今天没有课」；全部结束显示「今日课程已结束」。点击小组件任意区域 SHALL 经 `widgetURL` → `onOpenURL` → 深链进入课表 tab。

#### Scenario: 显示今天剩余课程
- **WHEN** 今日 10:00、8:00-9:35 的课已结束、10:00-11:35 与 14:00 的课未上
- **THEN** 小组件显示后两门课，10:00 的课卡片显示「约 95 分钟」倒计时

#### Scenario: 17:00 后切明天
- **WHEN** 今日 18:00 且今日末课已于 16:30 结束（或今日无课）
- **THEN** 头部显示「明天 · 星期X」，列表为明天课程（明天无课则显示「明天没有课」）

#### Scenario: 点击深链
- **WHEN** 用户点击小组件
- **THEN** 打开 App 并落在课表 tab

### Requirement: 小组件尺寸族
小组件 SHALL 支持 systemSmall（单列紧凑：头部 + 最多 2 门精简行「时间 课名 教室」）与 systemLarge（Medium 同款卡片 + 剩余课程完整列表，超出滚动或截断至空间上限）尺寸，systemMedium 为对齐 Android 的基准尺寸。**Android 对照偏差说明**：Android `SizeMode.Exact` 按 resize 精确尺寸自适应 compact/regular 双档；iOS 按系统固定 family 三档布局，语义等价（尺寸自适应）但档位离散。

#### Scenario: systemSmall 紧凑布局
- **WHEN** 用户添加 systemSmall 尺寸小组件
- **THEN** 显示头部 + 精简课程行（无教师与元数据分组）

### Requirement: 小组件数据管线（App Group 快照）
主 App 与小组件 SHALL 通过 App Group 容器共享数据：主 App 在课表变化（表切换/课程增删改/导入）、课表设置变化、小组件设置变化时导出**课表快照 JSON**（当前表元数据 + 节次配置 + 全部课程）写入 App Group 容器；小组件 `TimelineProvider` 读取该 JSON 本地计算显示状态，**不访问数据库**。主 App SHALL 在上述变化后调用 `WidgetCenter.shared.reloadTimelines` 触发刷新。快照 JSON 解析 SHALL 宽容（字段缺失/版本不识别时回退空态，不崩溃）。
**方案理由（对齐 handoff 建议）**：GRDB 库文件双进程共享虽技术上可行（WAL），但引入连接池竞争、迁移锁、文件访问协调复杂度；小组件只读课表小数据（≤ 数 KB JSON），快照导出简单可靠——选择 snapshot JSON 而非共享 DB。小组件背景图与不透明度设置 SHALL 存 App Group UserDefaults（小组件进程可读）。

#### Scenario: 改课后小组件刷新
- **WHEN** 用户在 App 内修改课程时间
- **THEN** 快照 JSON 重写、`reloadTimelines` 被调用、小组件下次渲染反映新课表

#### Scenario: 快照缺失回退
- **WHEN** 小组件首次添加而 App 从未导出快照
- **THEN** 小组件显示空态（如「今天没有课」）不崩溃

### Requirement: 小组件时间线
小组件 SHALL 以 `TimelineProvider` 预生成时间线：当日每个节次边界（课程开始/结束时刻）生成一个 entry（完成剩余课程过滤与「切明天」判定推进）、进行中课程的倒计时文本按分钟粒度生成 entry（每分钟一个，覆盖进行中课程时段，对齐 Android 分钟级闹钟刷新语义）、午夜后生成切日 entry；刷新策略 `.atEnd`。时间线生成 SHALL 为纯本地计算（无网络）。**平台语义差异说明**：Android 主动闹钟 + `updatePeriodMillis` 3h 兜底；iOS 无主动推送，时间线预生成将「未来的显示状态」提前算好交给系统，倒计时分钟 entry 即分钟级刷新的等价物，且不受系统刷新预算约束（预算只影响 timeline 重载，不影响已交付 entry 的展示）。

#### Scenario: 节次边界推进
- **WHEN** 时间线覆盖 10:00-11:35 的课程且当前 11:35
- **THEN** 11:35 的 entry 生效，该课程从剩余列表移除（若为末课则显示「今日课程已结束」）

#### Scenario: 倒计时分钟推进
- **WHEN** 课程 10:00-11:35 进行中且当前 10:20
- **THEN** 当前 entry 倒计时显示「约 75 分钟」，下一分钟 entry 显示「约 74 分钟」

### Requirement: 通知设置页
Me 设置 SHALL 新增「通知」入口，页含：新闻通知分组（开关 + 检查间隔 Picker：15 分钟/30 分钟/1 小时/3 小时/6 小时——间隔项在开关关闭时置灰）与课程提醒分组（开关），开关状态读写 `UserSettings` 对应字段（`newsNotificationEnabled`/`newsCheckIntervalMinutes`/`courseReminderEnabled`，iOS 已备）并**即时生效**（写入后触发对应调度器同步：抓取任务重排/提醒重排，对齐课表四开关 reloadPrefs 模式）；开启新闻通知开关时 SHALL 立即抓取一次作即时反馈。**裁剪说明**：Android 页内「系统权限」分组的电池优化与自启动两开关不移植（见通知权限申请需求）。

#### Scenario: 改间隔即时重排
- **WHEN** 用户将检查间隔从 1 小时改为 15 分钟
- **THEN** 后台抓取请求以新间隔重新提交（earliestBeginDate 更新）

#### Scenario: 开课程提醒即时排程
- **WHEN** 用户打开课程提醒开关且权限已授予、当前课表有课
- **THEN** 未来 14 天窗口内的课程提醒立即注册

### Requirement: 小组件设置页
Me 设置 SHALL 新增「小组件」入口，页含：顶部实时预览（静态示例数据 + 用户所选背景与不透明度实时反映）+ 背景图片分组（选择图片（存 App Group 容器文件）/ 移除背景（有背景时显示，红字））+ 背景不透明度分组（0-100% 滑块，默认 50%，对齐 Android 128/255）。任一变更 SHALL 写入 App Group UserDefaults 并触发小组件刷新。

#### Scenario: 选背景图即时反映
- **WHEN** 用户选择一张背景图
- **THEN** 图片保存至 App Group 容器、预览即时更新、桌面小组件下次刷新使用该背景

### Requirement: 日报设置分组
LLM 模型设置页 SHALL 新增「日报」分组（iOS 当前缺口，Android `LlmSettingsScreen` 同位）：日报开关（`dailyReportEnabled`）+ 生成时间（`dailyReportTime`，HH:mm，默认 00:10）；开关与时间变更即时生效（同步日报后台任务提交/取消）。时间选择 SHALL 仅在开关开启时可用。

#### Scenario: 关日报取消任务
- **WHEN** 用户关闭日报开关
- **THEN** 日报后台任务取消，后续不再自动生成
