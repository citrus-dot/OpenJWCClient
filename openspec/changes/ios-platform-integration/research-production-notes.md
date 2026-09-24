# 阶段 7 生产级调研补遗

> 调研目的（2026-09-24，Nironta 指示）：四件套立案后，对照 GitHub 主流仓库与 Apple 官方文档，把方案补到生产级软件标准、代码符合相关规范。本文是 design.md D-1~D-12 的**生产级增补**，结论表给出每条对本案的落点（采纳/已采纳/不适用），最后附「四件套修订点清单」指引 proposal/spec/design/tasks 的具体增补位置。型同阶段 6 [`research-webview-import.md`](../archive/2026-09-22-ios-timetable/research-webview-import.md) 的调研补遗格式。

## 一、调研范围（2026-09-24）

| 主题 | 来源 | 性质 |
|---|---|---|
| BGTaskScheduler 生产模式 | Apple 官方文档（`Using background tasks to update your app`）、WWDC19-707、Donny Wals / SwiftLee / CodePushGo / DEV 生产架构文、axiom-background-processing skill | 权威 + 实战 |
| BGTaskScheduler × Swift 6 严格并发 | HackerNoon「Amana 崩溃实录」、calcopilot「Swift 6 journey」、Swift Migration Guide | **运行时崩溃陷阱**（编译零警告仍崩） |
| WidgetKit containerBackground | Apple 官方「Displaying the right widget background」、WWDC23-10027「Bring widgets to new places」、SwiftSenpai / Filip Němeček hotfix 文 | iOS 17+ **必用** |
| App Group 数据共享 | SwiftLee（Core Data + 扩展）、Use Your Loaf（widget 数据共享）、polpiella（迁移）、hackingwithswift（SwiftData + widget） | 模式对比 |
| 同类开源项目 | **NetNewsWire**（Ranchero-Software，7.8k★，RSS 抓取+通知+widget，与本案权重合度最高）`Technotes/Widgets.md` + issue #2616 数据新鲜度提案 | **实证参照** |

## 二、派别 A — BGTaskScheduler 生产模式

### A-1 注册时机与队列语义（Apple 官方 + WWDC19-707）
- **注册必须在 App 启动完成前**：SwiftUI `App` 生命周期下，`App.init()` 是等价点（先于首帧渲染、先于 `didFinishLaunching` 等价语义返回）。`BackgroundTaskCoordinator` 的 `register(forTaskWithIdentifier:using:launchHandler:)` 放 `OpenJWCApp.init` 即满足。**已采纳**（design D-1）。
- `using: nil` → 系统创建后台串行队列，**launchHandler 在任意后台线程被调用**（非主线程）。
- identifier 必须与 `Info.plist` `BGTaskSchedulerPermittedIdentifiers` **大小写敏感**逐一对应。

### A-2 ⚠️ Swift 6 严格并发崩溃陷阱（HackerNoon Amana 实录 + calcopilot）
**这是本案最关键的生产级风险**，原 design 未覆盖：

- `AppEnvironment` 是 `@MainActor @Observable`（`AppEnvironment.swift:8-10`）；若在其中调用 `BGTaskScheduler.shared.register { task in ... }`，**闭包继承外围 `@MainActor` 隔离**；系统在后台队列调用该闭包 → Swift 6 运行时隔离检查在闭包**入口处**触发 `EXC_BREAKPOINT`，**早于闭包内 `Task { @MainActor in }` 执行**。编译器零警告、测试全绿、却在后台运行时崩溃。
- `task.expirationHandler` 同理（也在后台线程调用）。
- **修复模式**（calcopilot 验证）：把注册闭包与 expiration 闭包定义在 **`nonisolated static`** 函数里（不继承 `@MainActor`），闭包内只做一件事 —— `Task { @MainActor in shared.handle(task) }` 跳主线程。**闭包内不得触碰任何 @MainActor 状态（连 Logger 都不行）**，所有实质工作进 `Task { @MainActor in }`。
- 替代写法：`using: .main` 让系统在主队列调用（Amana 的 fix 之一），但官方文档建议 `nil` + 自管跳转；本案采用 `nonisolated static` 模式（对齐 calcopilot 推荐 + 与既有 actor 隔离一致）。

**落点**：design 增 D-13；spec「后台资讯抓取/日报定时生成」Requirement 增 Swift 6 隔离约束；tasks 7.1 增 nonisolated 闭包模板要求 + 单测/手验覆盖后台触发不崩溃。

### A-3 `submit` 三类错误（Apple 官方 + axiom skill）
`BGTaskScheduler.shared.submit(request)` throws：
- `.notPermitted`：用户在系统设置关闭了「后台 App 刷新」→ 静默吞、记日志，**不崩溃**；前台 Timer + 启动抓取兜底。
- `.tooManyPendingTaskRequests`：同 id 累积请求过多 → 静默吞；正常「每次运行末重排」不会触发。
- `.unavailable`：模拟器旧版本/能力不可用 → 调试期预期，**不报错给用户**。

**落点**：design D-1 增错误处理三态；tasks 7.3 增 catch 分支；spec 场景「后台抓取」不变（行为契约已涵盖）。

### A-4 `setTaskCompleted(success:)` 必须恰好一次（DEV / CodePushGo / axiom）
- **所有路径**（成功/失败/异常/expiration）都必须调 `setTaskCompleted`，否则系统降权该 app 后续调度预算。**最常见 bug = 装机后只刷新一次**（忘记在 handler 内重排下一次请求）。
- expirationHandler 应**先**设（首位）、**再**重排下一次、**再**起 work Task；work Task 的 `value` 收尾 + cancellation 路径都汇到 `setTaskCompleted`。
- work 必须幂等 + 可恢复（checkpoint）：本案水位机制（`markNotified` per-source）天然 checkpoint，中断的下轮照常作为新条目；日报 actor 状态机同样 checkpoint（RUNNING 落库，COMPLETED 不可覆盖）—— **已具备**，无需新增。

**落点**：design D-1/D-2 已隐含，增显式约束；tasks 7.3/7.4 增「所有路径 setTaskCompleted」 checklist 项。

### A-5 模拟器/真机测试手段
- LLDB 私有 API `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"org.openjwc.newsrefresh"]`（同族 `_simulateExpirationForTaskWithIdentifier:`）—— 调试器附加时可用，模拟器 + 真机均有效。
- Xcode Debug 菜单「Simulate Background Fetch」（旧 UIApplication fetch，对 BGTaskScheduler 部分生效）。
- 真机准点等待不现实 → **验收口径**：模拟器 earliestBeginDate 压缩到分钟级 + LLDB 强制触发 + 前台补偿为主，真机准点性不做验收项（design D-9 已固化，对齐产品文案「尽力而为」口径）。
- 模拟器 BGAppRefresh 最早 15 分钟下限可能被系统加速到秒级触发 → 可直接等待观测。

### A-6 force-quit 行为
用户从 App Switcher 上划强杀 → 已排程的 BGTask **全部停止**直到下次用户主动启动 App。本案启动路径全量重排（bootstrap）天然覆盖此场景的恢复；产品文案无需特殊说明（用户重新打开即恢复）。

## 三、派别 B — WidgetKit 生产模式

### B-1 ⚠️ `containerBackground(for: .widget)` iOS 17+ 必用（Apple 官方 + WWDC23-10027）
- iOS 17 起 widget 出现在新位置：iPhone **StandBy**、iPad 锁屏、Apple Watch Smart Stack、Mac 桌面。系统在 StandBy/锁屏会**移除 widget 背景**以适配环境；要求开发者用 `containerBackground(for: .widget) { ... }` 显式标记背景层。
- **不采用** → 开发期预览画布报「please adopt containerBackground API」覆盖警告、StandBy/iPad 锁屏渲染异常。
- 本案 `deploymentTarget iOS 18.0`（`project.yml`）→ **必须采用**。
- `containerBackgroundRemovable(_:)` 配置：背景即内容（如纯照片 widget）置 `false`（牺牲 StandBy/锁屏资格）；普通内容 widget 默认 `true`。

**本案决策**：课程小组件背景 = 用户可选图 + 不透明度（design D-8/D-7）——
- 无背景图时：`containerBackground(for: .widget) { Color(...) }`，可移除（默认 true），StandBy 显示无背景版；
- 有背景图时：`containerBackgroundRemovable(false)`（用户显式设了背景，应始终可见；放弃 StandBy/锁屏资格——对齐 Android 行为：背景始终在）。

**落点**：design D-6/D-10 增 containerBackground 强约束 + 双态策略；spec「课程小组件」Requirement 增 SHALL 采用 containerBackground 修饰符；tasks 10.2 增该约束。

### B-2 `contentMarginsDisabled()` 与 `widgetContentMargins`
- iOS 17 系统自动加 content margin（防内容贴边）；如需内容到边（对齐 Android 紧凑布局）用 `.contentMarginsDisabled()` 或读 `@Environment(\.widgetContentMargins)` 自加 padding。
- 本案 Medium 课程卡布局对齐 Android 紧凑 → 倾向 `contentMarginsDisabled()` + 自管内边距。

### B-3 刷新预算与 `reloadTimelines` 节流（WWDC + 实战）
- 系统对 widget timeline **重载**有日预算（约 40-70 次/天，随设备使用习惯）；**已交付 entry 的展示不受预算约束**（design D-6 已正确利用此特性做分钟级倒计时）。
- `WidgetCenter.shared.reloadTimelines` / `reloadAllTimelines` 调用过频会被节流 → 仅在真有数据变化时调（课表变化/小组件设置变化/抓取完成），**不**每分钟调。
- 本案触发点（design D-8）已收敛到「课表/设置变化」 → 符合节流纪律；倒计时分钟推进走时间线 entry 而非 reload，正确。

### B-4 App Group 数据共享 —— snapshot JSON 是主流正解（多源印证）
- **NetNewsWire**（7.8k★ RSS reader，与本案权重合度最高）：widget **不访问主 app DB**；`WidgetDataEncoder` 把少量文章数据编码 JSON 存 App Group 容器；**两个写入时机**：①后台刷新时 ②scene 进入后台时；每次写后 `WidgetCenter.shared.reloadAllTimelines()`；medium widget 用 `widgetURL` 深链 `nnw://showunread?id={articleID}` → 主 app `scene(_:openURLContexts:)` 消费。← **逐项对齐本案 design D-7 snapshot JSON + D-8 触发链 + 既有深链链路**，是生产级实证。
- **Use Your Loaf**：「Do you need to use Core Data with a widget? A widget shows a small amount of information. My preference would be to extract the data you need in the main App and share it as a simple plist or JSON file.」← **直接背书本案 D-7 的方案 b（snapshot JSON 而非共享 DB）**。
- **SwiftLee**：共享 Core Data 需 App Group 容器 URL + Persistent History Tracking + Darwin Notification 跨进程通知；复杂度高、双进程写有竞态。← **背书本案 D-7 对方案 a（共享 DB）的否决理由**。
- SwiftData + widget（hackingwithswift）：`modelContainer()` + App Group 自动迁移；本案用 GRDB 非 SwiftData，不适用，但印证「App Group 容器是唯一共享路径」。

**落点**：design D-7 已采纳方案 b，无需改动；调研附录为决策补强第三方实证；spec「小组件数据管线」Requirement 不变。

### B-5 背景图内存与降采样（生产级缺口，原 design 未覆盖）
- widget extension 进程内存上限 ~30MB；用户选的相册原图可能数 MB-数十 MB；直接存原图 → widget 渲染时解码吃内存 + 加载慢。
- 生产做法：选图时**降采样 + 重编码 JPEG**（目标边长 ≤ 1080-1280px、quality 0.7-0.8），存 App Group 容器小文件（≤ 数百 KB）。
- Android 端 `WidgetSettingsScreen.saveBackgroundImage`（:370-383）仅 `copyTo` 原图 → 同样有此问题，iOS 应**优于** Android（修一个上游缺口）。

**落点**：spec「小组件设置页」Requirement 增「选图时降采样重编码」SHALL；design D-8/D-10 增 `WidgetImageProcessor`（downsample + JPEG re-encode 纯函数/actor）；tasks 12.1 增该项。

### B-6 widget target 依赖与死代码剔除
- widget appex 依赖 `OpenJWCCore` 本地包：GRDB/SwiftSoup/JavaScriptCore 静态链接进 appex，但 widget 不触达 → Swift 全模块优化死代码剔除，体积/内存影响可忽略。design D-7 已采此决策。
- 备选「拆 `OpenJWCWidgetShared` 极简模块」否决理由：模块手术成本 > 收益，阶段 8 打磨期再评估。**保持原决策**。

## 四、派别 C — 同类开源项目对照

### C-1 NetNewsWire（Ranchero-Software/NetNewsWire，MIT，7.8k★）
最接近本案的资讯类生产级 iOS app：RSS 抓取 + 本地通知 + widget + 后台刷新。逐项对照：

| 维度 | NetNewsWire 实现 | 本案 iOS 决策 | 一致性 |
|---|---|---|---|
| widget 数据共享 | **不访问主 app DB**，`WidgetDataEncoder` 编码 JSON 存 App Group，两时机写入（后台刷新 + scene 进后台） | D-7 snapshot JSON，写入时机 = 课表/设置变化（本案 widget 是课表不是资讯，故时机不同但模式同） | ✔ 模式一致 |
| timeline 刷新 | 写后 `WidgetCenter.shared.reloadAllTimelines()` | D-8 `reloadTimelines(ofKind:)`（按 kind 更精准） | ✔ 本案更优（按 kind 而非全量） |
| 深链 | `widgetURL`/`Link` + `nnw://showunread?id=...` → `scene(_:openURLContexts:)` | `widgetURL` → `onOpenURL` → `AppRouter` 深链（既有链路） | ✔ |
| 后台刷新频率局限 | issue #2616 提案：BGTask 频率不足 → 服务器 silent push 分组（token_group 0-5，每设备日 4 次唤醒） | 本案无服务器，接受 BGTask 频率局限 + 前台 Timer 补偿；产品文案声明「尽力而为」 | ✔ 范围内最优，silent push 列为未来增强 |
| 数据新鲜度策略 | 服务端推送 + 客户端 BGTask + 前台刷新 三层 | 客户端 BGTask + 前台 Timer + 启动抓取 三层（无服务端层） | ✔ 范围对齐 |

**结论**：本案的客户端侧架构选择（snapshot JSON + BGAppRefresh + 前台 Timer + 深链复用）与 7.8k★ 生产级 RSS reader **逐项一致或更优**，无需调整主干；silent push（C-1 issue #2616 派生）列为**未来增强**（对齐阶段 6 把 WebView 升级列为未来变更的先例），不纳入本案。

### C-2 Apple 官方示例 Emoji Rangers（WidgetKit + Live Activities）
- 用 `containerBackground(for: .widget) { Color.gameBackground }` 标记可移除背景（B-1 来源）；`.widgetAccentable()` 标记 accent 色在 vibrant 模式保持可见。
- 本案课程色条/倒计时文本可考虑 `.widgetAccentable()`（vibrant/锁屏模式下保持关键色可见）——**列为实现期可选增强**，不强制。

### C-3 课程表类开源项目
- GitHub 上 iOS 课程表 + WidgetKit 开源项目稀缺且质量参差（多为单文件 demo，无 App Group + 后台刷新 + 通知全链路）；NetNewsWire 已是更权威的对照基线，不另列。

## 五、结论表（对本案的落点）

| 调研发现 | 落点 | 动作 |
|---|---|---|
| BGTask register 须在启动完成前 | design D-1 已采（`OpenJWCApp.init`） | 无改动 |
| **Swift 6 闭包继承 @MainActor 隔离 → 后台崩溃** | design/spec/tasks 未覆盖 | **D-13 新增 + spec 增约束 + tasks 增 nonisolated 模板** |
| `submit` 三类错误需静默处理 | design D-1 未显式 | D-1 增错误三态 |
| `setTaskCompleted` 所有路径恰好一次 | design D-1/D-2 隐含 | 显式约束 + tasks checklist |
| force-quit 停止 BGTask | 启动全量重排已覆盖 | 无改动（产品文案不特殊说明） |
| **`containerBackground(for: .widget)` iOS 17+ 必用** | design/spec 未覆盖 | **D-13 新增 + spec widget Requirement 增 SHALL + tasks 10.2 增** |
| `contentMarginsDisabled` 紧凑布局 | design D-6 隐含 | D-6 显式 |
| 刷新预算 + reloadTimelines 节流 | design D-8 已收敛触发点 | 无改动，D-6 增节流纪律显式 |
| snapshot JSON 是 widget 数据共享主流正解 | design D-7 已采纳 | 第三方实证补强（本附录 C-1/派别 B） |
| **背景图降采样重编码** | design/spec 未覆盖 | **spec 增 SHALL + D-13 增 WidgetImageProcessor + tasks 12.1 增** |
| NetNewsWire 实证本案主干架构 | 全局背书 | 无改动 |
| silent push 频率增强 | 范围外 | 列为未来增强（同阶段 6 WebView 先例） |

## 六、四件套修订点清单（→ 下一节执行）

1. **proposal.md**：Impact 增「Swift 6 隔离处理 + containerBackground + 背景图降采样」三项生产级约束；Non-goals 增「silent push 服务端增强」未来增强项；风险项细化 Swift 6 崩溃陷阱。
2. **spec.md**：①「课程小组件」Requirement 增 SHALL 采用 `containerBackground(for: .widget)`、有背景图时 `containerBackgroundRemovable(false)`；②「小组件设置页」Requirement 增 SHALL 选图时降采样重编码 JPEG；③「后台资讯抓取/日报定时生成」Requirement 增「BGTask 注册闭包与 expirationHandler 闭包定义于 nonisolated 上下文，实质工作经 `Task { @MainActor in }` 跳主线程」SHALL（Swift 6 隔离）；④「后台资讯抓取」增 `submit` 三类错误静默处理 SHALL。
3. **design.md**：新增 D-13 生产级增补（Swift 6 隔离模板 + containerBackground 双态 + 背景图降采样 + submit 错误处理 + setTaskCompleted 全路径 + reloadTimelines 节流纪律显式）。
4. **tasks.md**：7.1 增 nonisolated 闭包模板 + 后台触发不崩溃手验；7.3 增 submit catch 三态 + 所有路径 setTaskCompleted checklist；10.2 增 containerBackground 双态 + contentMarginsDisabled；12.1 增背景图降采样重编码；10/12 各增 widgetAccentable 可选增强备注。
5. **openspec validate 复跑**。
6. **docs/ios-stage7-handoff.md 更新**：评审状态、调研附录指引、生产级要点清单（Swift 6 陷阱/containerBackground/降采样三条红线）。
7. **ai-memory handoff**：下一会话 SessionStart 自动注入本案状态 + 三条生产级红线 + 待评审。

## 七、7a 实施期补遗（2026-09-24 手验实录，iOS 26.5 模拟器）

### 7.1 ATS 明文拦截（阶段 4 遗留 bug，7a 手验发现并修复）

- **现象**：抓取控制台刷 `NSURLErrorDomain Code=-1022 "App Transport Security policy requires the use of a secure connection"`，URL 为 `http://jwc.seu.edu.cn/...`（脚本拼出的明文分页 URL）。
- **根因**：主 app Info.plist 从未配置 ATS 例外（阶段 4 漏项）；iOS 默认拦截 `http://` 明文请求。Android 无此限制（功能不缺失对照基准的又一平台差异，此前未被覆盖）。
- **修复**：`NSAppTransportSecurity → NSAllowsArbitraryLoads = true`（Info.plist + project.yml 同步）。逐域白名单不现实（39 个内置源域名杂、明文 https 混用、脚本动态拼 URL）；源均为公开高校新闻站，与 Android 对齐语义，风险可接受。
- **影响**：部分仅提供 http 的源在 iOS 端此前**从未抓取成功**；修复后恢复（对齐 Android 功能面）。

### 7.2 BGTaskScheduler 模拟器不可用（Code=1 Unavailable 实录）

- **现象**：`submit` 抛 `BGTaskSchedulerErrorDomain Code=1`（`BGTaskSchedulerErrorCodeUnavailable`）；`_simulateLaunchForTaskWithIdentifier` 报 `No task request ... has been scheduled`（无提交自然无 handler 可调）。
- **结论**：**iOS 26.5 模拟器不支持 BGTaskScheduler**（系统限制，非代码缺陷；与调研期「模拟器可观测」的预期不符）。register 不报错、白名单/后台模式均在产物 Info.plist 中验证正确。
- **验收口径调整（取代 D-9 中「模拟器提交后等待观测」与 LLDB 强制触发的部分）**：
  - 模拟器可验：前台全链路——权限流、通知设置页、开关 runOnce 立即抓取发通知、通知点击深链、课程提醒注册与触发（UNUserNotificationCenter 与 BGTask 无关，完全可用）、前台 Timer、日报前台补偿、`setTaskCompleted`/续排逻辑（单测覆盖纯函数部分）。
  - **真机验收项（延至阶段 8 免签侧载一并执行）**：后台任务实际触发不崩溃（红线 1 的最终实证）、expiration 续排、force-quit 恢复。
  - 代码侧红线 1 的静态保障不变（nonisolated static 模板已实施，编译期 + 单测锁定）。

### 7.3 submit 诊断日志

`submitNewsTask`/`submitDailyReportTask` 成功与失败路径均增 `NSLog`（成功含 earliest 参数；失败含完整 Error Domain/Code）——静默吞错误的设计保留，但排障可观测（本次即靠它定位 Code=1）。
