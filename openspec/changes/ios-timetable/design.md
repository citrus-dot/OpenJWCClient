# Design: ios-timetable

> 调研基准：Android 真源 `ui/timetable/` 37 文件 + `TimetableViewModel`/`EditCourseViewModel`/`TableConfigViewModel`/`CourseRepository`/`TableParserUtils`/`CourseColors` + `timetable_extractor.js` 全部通读（2026-09-22）；本工作区 HEAD 已含上游 `a8146ed`（长按拖拽）+ `e547b9a`（拖拽浮层尺寸动画）终态。本文按交接文档 7 个调研问题逐条给出答案与决策。

## D-1 周视图布局技术路线（调研问题 1）

**Android 算法事实**（`TimetableGrid.kt` + `CourseLayer.kt` + `TimetableGridUtils.kt`）：
- 分层结构（自底向上）：`GridBackgroundLayer`（单 Canvas 画网格线 + 活跃节行高亮 + 单 `pointerInput` tap 定位空槽）→ `TimeIndicatorLine`（zIndex 3）→ 非本周课程泳道块（zIndex 1）→ 本周课程全列宽块（zIndex 2）→ 拖拽浮层（zIndex 10）。
- `periodHeight = max(60dp, 可用高 ÷ 节数)`；列宽 = `(总宽 − 44dp 节次栏) ÷ 可见天数`；本周块 y = `periodHeight × (startPeriod − 1)`（1-based 节号）。
- 非本周泳道三步：①按本周课程占用节次裁剪（拖动中的课程不占位，露出下层）②`findContinuousBlocks` 拆连续段 ③`assignLanes`：按段起始节排序，`start > groupEnd` 则 flush 前组（传递性重叠分组），组内按 `laneEnds.indexOfFirst { it < start }` 贪心取空闲泳道；组宽 = 列宽 ÷ 组内泳道数，x = 泳道宽 × lane。
- 块尺寸动画：`SizedCourseBlock` 用 `Animatable<Dp>` + spring(700f, 0.85f)，初始尺寸可从拖拽落位浮层尺寸过渡（`lastDropped`）。

**iOS 候选与取舍**：

| 方案 | 说明 | 取舍 |
|---|---|---|
| a. 自定义 `Layout` protocol | lane 布局天然适合 placeSubviews | **弃**：浮层跨层 zIndex、拖拽 offset 逃逸布局边界、块动画与 Layout 的 sizeThatFits 交互复杂；收益仅理论性能 |
| b. 全 Canvas 绘制 | 一个 Canvas 画全部 | **弃**：丢失每课程独立视图的交互（长按手势、点击、按压缩放、尺寸动画），与「课程块是可交互实体」的需求冲突 |
| c. ZStack + offset/frame + Canvas 背景（**采用**） | 等价 Android 结构：`Canvas`/`drawBehind` 画网格线与活跃行；课程块为真视图 `.offset(y:).frame(width:height:)` 定位；浮层 `.zIndex(10)` | 与 Android 行为一一映射，拖拽/动画/点击全部自然落地；每列课程数有限（≤ 非本周几十块），性能无虞 |

**落点**：`app/Features/Timetable/TimetableView.swift`（页面：pager + 顶栏 + 网格）、`TimetableGridView.swift`（单周网格：背景 Canvas + 课程层 + 浮层）、`CourseBlockView.swift`（块：内容规则 + 缩放 + 手势）。lane/segment/落点/冲突算法**不写在视图里**，下沉 core 纯函数 `TimetableLayout.swift`（见 D-7 测试策略）。

## D-2 拖拽交互（调研问题 2）

**Android 交互事实**（`TimetableDragState.kt` + `TimetableGrid.kt:139-223` + `CourseBlock.kt:135-149`）：
- 手势：`detectDragGesturesAfterLongPress`（长按后拖动，onDrag 消费增量）；`rememberUpdatedState` 防指针协程捕获旧闭包。
- 浮层：拖起时原块 alpha 0、浮层宽高从原尺寸 spring(700/0.85) 过渡到整列宽 × 全课高；拖动缩放 1.06。
- 落点 `resolveDropTarget`：块水平中心定列（`toInt + coerceIn`）；上边缘定节（`roundToInt + coerce(0, 节数−duration)`）；`endPeriod > 末节` 越界或 `isConflictingWith` 冲突 → null → `snapBack`（220ms tween 回原位，scale 1.06→1.00）。
- 落位：220ms tween lerp 到目标 + `settleScale` 回落 → 动画完成后才 `onCourseMove` 提交 → `pendingMove` 等 `courses` 流反映新位置才撤浮层（防写入间隙旧位闪现），1s 兜底强撤。
- 按压缩放 0.97（spring 800/0.5）；动画开关（`ThemeConfig.animationsEnabled`）0 时瞬切。

**iOS 决策**：不用系统 `draggable`/`DropDelegate`——那是跨视图拖放语义（系统接管预览放大、跨容器落点协商），拿不到「原位 overlay + 落位动画 + 网格内解算」。用 **`LongPressGesture(minimumDuration:).sequenced(before: DragGesture)` 自管手势**：`@Observable` 的 `TimetableDragState`（draggingCourse/dragPosition/originalPosition/startSize）等价直译；浮层 `.offset` + `.zIndex(10)`，宽高用 `Animatable<CGSize>` 对（或两个 `Animatable<CGFloat>`）+ `spring(response:dampingFraction:) ≈ Compose spring(700/0.85)`；落位/回弹用 `withAnimation(.easeInOut(duration: 0.22))`（对应 tween 220ms）；数据反映撤浮层用 `onChange(of: courses)` + `Task.sleep(1s)` 兜底。SwiftUI 闭包读 `@Observable` 状态天然是最新值，无需 rememberUpdatedState 等价物。

**落点**：`TimetableDragState`（app 层 @Observable）+ core `TimetableLayout.resolveDropTarget`（纯函数）。

## D-3 学期周次与周切换（调研问题 3）

**语义一致性核验（已完成）**：iOS `GrdbTimetableSource.currentWeek(startDate:weeks:today:timeZone:)`（`Corpus.swift:210-222`，firstWeekday=2、越界 nil、区间内 clamp(1, weeks)，有单测）与 Android `SemesterConfig.calculateCurrentWeek`（`TimetableModels.kt:105-112`，startMonday = startDate.with(MONDAY)、endSunday = startMonday+weeks×7−1、越界 nil、daysBetween/7+1 coerce）**语义一致** ✔。UI 侧沿用 `GrdbTimetableSource` 的实现，不另写第二份。

**周次条范围展示规则**（Android 事实）：无独立周次条——页 = 周（`HorizontalPager` pageCount=weeks，initialPage=currentWeek−1）；顶栏「第 N 周」胶囊（`TopAppBar.kt`）。表切换时 `calculateCurrentWeek() ?: 1`；`syncToActualWeek`：`today < startDate → 1`，否则 clamp。**注意 Android 的 `onWeekClick` 实际为空实现**（周切换只靠滑页），iOS 对齐：胶囊不做点击交互（或做点击弹周选择为 iOS 增强——**不采用**，保持对齐）。

**双向同步机制**：`settledPage → setWeek(fromPager: true)`；`currentWeek 变化 → isInternalWeekUpdate ? scrollToPage(无动画) : animateScrollToPage`，consume 后复位。iOS 等价：`TabView(.page)` + `onChange(of: pager 当前页)` + `scrollPosition` API（iOS 18 `TabView` page 式支持 `scrollPosition(id:)` 程序滚动）；内部/外部区分用同一 `isInternalWeekUpdate` 标志模式。日期表头：`weekStart = startDate + (N−1) 周` 归一周一，今天胶囊高亮，`Timer` 对齐午夜刷新（Android 是 delay 到午夜）。

## D-4 数据流与观察（调研问题 4）

**Android 数据流**：`allTables`/`currentTable`（Room Flow）/`currentCourses`（`observeCurrentTable().flatMapLatest { getCoursesByTableId }` 级联）/`displayPrefs`（DataStore userSettings map）→ StateFlow。

**iOS 决策**：沿用阶段 5 验证的 **GRDB 单闭包 ValueObservation 多表组装**模式（`ReactiveStore` 同款）：`TimetableStore`（@MainActor @Observable）持一条观察：

```swift
let obs = ValueObservation.tracking { db -> TimetableDataSnapshot in
    let tables = try TableMetadataRecord.fetchAll(db, ...)   // allTables
    let current = tables.first(where: \.isCurrent)            // currentTable
    let courses = current.map { try CourseRecord.fetchAll(其中 tableId) } ?? []
    return TimetableDataSnapshot(tables: tables, current: current, courses: courses)
}.removeDuplicates()   // CourseRecord: Equatable
```

一次写库（拖拽/编辑/导入）→ 快照整体推送，天然覆盖 Android 的 flatMapLatest 级联语义，无观察泄漏（对比 Android 每表换订阅）。`displayPrefs` 走 `SettingsStore.userSettings` 读取（阶段 5 Me 已建读取模式）。`activePeriodIndex`（当前节）：分钟对齐 Timer（Android `delay(60_000 − now%60_000)`），iOS 用 `Task.sleep` 到下一整分等价实现，存 `TimetableStore`。

**`SettingsStore.currentTableId` 联动结论**：Android 的当前表真源是 **`table_metadata.isCurrent` 标记列**（`TableDao.setCurrentTable` 原子事务清零置位），`UserSettings.currentTableId` 字段在 Android 端同样是闲置的对齐字段。iOS **对齐此契约**：isCurrent 列为唯一真源（`TimetableDao.setCurrentTable` 已实现），`currentTableId` 保留不读（写入 spec）。

## D-5 Agent 工具接入（调研问题 5）

**核验结论：接线仅需一行**。`AgentTools` 构造已含 `timetable: (any TimetableSource)?` 参数（`AgentTools.swift:34-44`）且课表四工具（`get_timetable`/`list_timetables`/`get_courses_on`/`find_course`）spec 与 execute 已全量实现；`GrdbTimetableSource` 已就绪。`AgentRuntime.makeLoop()`（`ios/OpenJWC/App/AgentRuntime.swift:32-37`）当前只传 `GrdbNoticeCorpus`，改为：

```swift
let corpus = GrdbNoticeCorpus(db: db)
return AgentLoop(
    client: client,
    tools: AgentTools(repository: corpus, timetable: GrdbTimetableSource(db: db)),
    repository: corpus
)
```

`ChatService` 与 `DailyReportService` 均经 `makeLoop()` 组装，单点接线全覆盖，无需其它改动 ✔。

## D-6 WebView 导入裁剪（调研问题 6 —— 已决策：方案 b）

**决策结论（2026-09-22 Nironta 拍板）**：本案选 **方案 b = JSON 文件导入先行、WebView 教务导入延后另立 change**。下方 a/b/c 候选表与利弊对比作为决策追溯保留；末段「调研补遗」记录 GitHub 主流方案调研结论，提示未来升级到 a 时应优先考虑方案 d=WebView+LLM 而非硬编码 extractor。

**Android 事实**：`ImportWebViewScreen` = WKWebView 等价物（JS + DOM storage + mixed content + 移动 UA）加载 `http://ehall.seu.edu.cn/appShow?appId=4770397878132218` → 用户登录并看到课表 → 手动点 FAB → `evaluateJavascript(timetable_extractor.js)`（65 行：同步 XHR 拉 `/jwapp/sys/wdkb/modules/jshkcb/xnxqcx.do` 定位学期 + `xskcb.do` 拉课表，教务字段 KCM/SKJS/JASMC/SKXQ/KSJC/JSJC/ZCMC/KCH/JXBQH → 规范化 rows）→ `window.AndroidBridge.sendData(JSON)` 桥回传 → 与文件导入共用 `handleImportedJson → pendingImport → TableConfigDialog` 预览确认链路。

**候选方案**：

| 维度 | a. WKWebView 等价移植 | b. JSON 先行，WebView 延后（**推荐**） | c. 完全裁剪 |
|---|---|---|---|
| 实现成本 | 高：WKWebView + `WKScriptMessageHandler` 桥（脚本 `window.AndroidBridge` 守卫需适配为 `window.webkit.messageHandlers` 双写版）+ 脚本资产打包 + 登录态/重试页/加载错误 UI，约 2–3 个工作日 + 需真实教务账号手验 | 低：`fileImporter`/`fileExporter` 一天级；解析/预览链路与 Android 完全共用 | 零 |
| 功能效果 | 功能全集 100%（D10 满分） | 迁移/备份闭环保住（导出↔导入、与 Android 端互通）；「从教务直接抓」缺位 | 缺导入互通，违反 D10 |
| 维护性 | ehall 前端改版即失效（脚本选择器/接口路径硬编码）；桥协议双端分叉 | 后续若做，独立 change 边界清晰 | — |
| 风险 | WKWebView mixed content/ATS 例外（http 站点需 Info.plist 配置）；模拟器验证受校园网/账号可得性制约 | 无 | 用户预期落差 |
| 回退难度 | 低（独立页面，可后补） | 低（本案即 b；后续 change 升级到 a 零返工——解析链路共用） | 高（丢失互操作） |

**推荐 b 的理由**：JSON 导入导出（上游 `e44bf35`）已覆盖课表数据获取的核心价值（换机/双端互通/A 备份），且与 a 方案**共用全部解析与预览代码**——将来补 WKWebView 页面零返工；而 a 的增量收益（免手动导 JSON）伴随账号依赖的手验成本与 ehall 改版脆弱性。阶段 7（平台集成）或之后以独立 change 补 a。

**若未来升级到 a 时的追加范围（保留作未来变更参考）**：`ImportWebViewScreen` 等价页（`WKWebView` + 注入改造版 extractor（桥调用改 `window.webkit.messageHandlers.iosBridge.postMessage`，保留 AndroidBridge 守卫兼容 Android 端脚本复用）+ 资产 `Resources/Scripts/timetable_extractor.js` + ATS 例外（`NSAllowsArbitraryLoadsInWebContent`）+ FAB「看到课表点我」+ 加载失败重试页 + `pendingImport` 成功后 pop）。spec 的 REMOVED 段相应改为 ADDED。**调研补遗段建议**：未来升级优先考虑「方案 d=WebView+LLM 读页面文字」（见下），而非本段所述的硬编码 extractor 脚本方案 a。

## D-6-补 调研补遗：GitHub 等主流项目教务导入方案对照（2026-09-22 增补）

针对「WebView 教务导入」是否还有比 Android 现有 `ImportWebViewScreen` 更优秀的方案，调研 GitHub / Gitee / 掘金 / Apple App Store 同类主流项目。**详细记录见** [`research-webview-import.md`](./research-webview-import.md)（仅保留有效派别 ①③④，不纳入的派别②已在调研范围说明段标记不予吸纳的理由）。

**核心结论**（详见调研附录）：

| 时间窗 | 推荐方案 | 理由 |
|---|---|---|
| **本案 6b（阶段 6）** | 方案 b（JSON 文件导入） | 阶段 6 主线是课表核心移植，三派都需额外复杂度，不匹配 |
| **未来升级 WebView 时** | **方案 d（WebView + LLM 读页面文字）**（派别④，代表 SleepDown） | 跨校通用、抗 ehall 改版（DOM 文字结构比 API 稳定）、合规、与本案 b 共用全部解析与预览代码、升级零返工 |
| **阶段 8（AI 增强导入）** | 方案 e（AI 截图识别）（派别③，代表 Meet/YIClass/next_class/析课） | 完全无 WebView 依赖的跨校通用轻量补充；需多模态模型选型与成本评估 |
| **不吸纳** | 方案 a（硬编码 extractor 脚本）（派别①，本案 Android 现状） | 在方案 d 出现后已无优势；脚本绑死单校、改版即失效 |
| **不吸纳** | 方案 ②（云端脚本可更新）（派别②，代表 DawnCourse） | 不符合单体 iOS App 架构边界（运维独立 server 仓库 + Docker Compose） |

**关键复用资产**（本案 6b 实施后留给未来升级用的底子）：
- `TimetableJson.parseExternal`——LLM 输出天然落点
- `TableConfigSheet`——预览确认链路
- `TimetableService.confirmImport`——落库事务
- `AgentTools` 模型路由——LLM 调用基础设施


## D-7 样式与配色（调研问题 7）

**Android 事实**：种子色 16 色板（`Color.kt:70-75`，Material 800 级硬编码）；块渲染色由 `CourseColors.kt` 生成：`Blend.harmonize(seed, themePrimary)`（MaterialKolor）→ `TonalPalette` → container（浅 90/深 30）+ content（浅 10/深 90）+ accent（40/80）。确定性分配：`TableParserUtils.getDeterministicColor`（`abs(name.hashCode()) % 16`）与 `EditCourseViewModel.onNameChange`（`(name.hashCode() and 0x7FFFFFFF) % 16`）。

**iOS 决策（两处显式偏差 + 一处关键移植）**：
1. **不移植 `Blend.harmonize`（向主题主色靠拢）**：iOS 不引入 MaterialKolor 等价库；课程色块本身已是高饱和彩色，harmonize 的调和增量极小。**替代**：16 色板每色预计算浅/深两态（浅色模式 container = 种子色调亮至亮度 ~0.90 / 深 = 调暗 ~0.30，content 自动取对比色）——实现为 seed → HSB 亮度重映射的纯函数 + 常量校验单测。**偏差理由记入 spec 评审口径**：视觉语义等价（container/on-container 角色），省一整个三方色彩算法。
2. **玻璃就地采用（D-8 口径）**：顶栏（`navigationBarTitleDisplayMode` + toolbar 背景 `Bar` 玻璃）、周胶囊/FAB（`ultraThinMaterial`）、各 sheet 系统默认。**网格本体不用玻璃**（背景 Canvas 画线，保持可读性，与 Android 一致 plain surface）。
3. **关键移植——Java 语义 hashCode**：Swift `String.hashValue` 按**进程随机播种**，绝不可用于持久性配色。core 新增 `stableJavaHash(_ s: String) -> Int32`（UTF-16 码元多项式 ×31 直译 Java `String.hashCode`），配`「中文/ASCII/混合样例与已知值」对照单测。这同时保证：同名课程跨启动同色、同 JSON 在 Android/iOS 双端同色。编辑器自动配色与导入解析共用此函数（Android 两处实现 `abs` vs `and 0x7FFFFFFF` 在 Int32 域等价，iOS 统一取后者）。

## D-8 core 纯函数层设计（新增文件）

```
Packages/OpenJWCCore/Sources/OpenJWCCore/Timetable/
├── TimetableLayout.swift     # lane/segment/落点/冲突/周次文案（全静态纯函数）
├── TimetableJson.swift       # 导入解析 + 导出序列化 + TimetableParseResult
└── TimetableService.swift    # 表 CRUD 编排 + 导入落库事务 + currentWeek 同步
```

- `TimetableLayout`：`visibleSegments(dayCourses:currentWeek:draggingId:)` → `[Segment(course, periods, lane, laneCount)]`（内部：本周占用集 → 裁剪 → `findContinuousBlocks` → `assignLanes`，逐行直译 `CourseLayer.kt:49-79` 与 `assignLanes`）；`resolveDropTarget(...)`（直译 `TimetableGrid.kt:330-367`，输入输出全部值类型）；`isConflicting(_:_:)`（直译 `TimetableModels.kt:77-85`）；`formatWeekRule(...)`（直译 `TimetableGridUtils.formatWeekRule`）。
- `TimetableJson`：`parseExternal(json:) throws -> (TableMetadataRecord, [CourseRecord])`（直译 `CourseRepository.parseExternalJson` + `TableParserUtils`：weeks 三态提取、`"null"` 清理、行丢弃、weeks/weekend/maxPeriod 推断、13 节扩展、表名时间戳）；`buildExport(table:courses:) -> String?`（直译 `TimetableViewModel.buildExportJson`：规范化键、可选字段非空才写、2 空格缩进、空表 nil）；`stableJavaHash`；`courseBackgroundColors: [Int64]`（16 ARGB 常量）。
- `TimetableService`：`createTable`（落库+切换+周同步）、`updateTable`（含「当前周 > 新 weeks 则 clamp」）、`deleteTable`（删当前 → 切剩余首表 → 周同步，无剩余周=1）、`switchTable`、`saveCourse`/`removeCourse`、`confirmImport(metadata:courses:)`（事务：saveTable → 重映射 tableId → upsertCourses → setCurrentTable → 周=1）。全部走既有 `TimetableDao`（upsert 语义已被单测锁定）。

## D-9 app 层文件落点

```
ios/OpenJWC/Features/Timetable/
├── TimetableRootView.swift      # 页面骨架：顶栏（表名/周胶囊）+ pager + 空态引导 + 菜单
├── TimetableGridView.swift      # 单周网格：背景 Canvas + 课程层 + 指示线 + 浮层
├── CourseBlockView.swift        # 课程块（内容规则/缩放/长按拖拽手势）
├── TimetableHeaderRow.swift     # 周日期表头（今天高亮/午夜刷新）
├── PeriodLabelColumn.swift      # 左侧节次标签列
├── TimetableStore.swift         # @Observable：观察快照 + currentWeek 状态机 + drag state
├── CourseDetailSheet.swift      # 课程详情
├── EditCourseSheet.swift        # 课程编辑器（含周次选择/色板/冲突提示）
├── TableConfigSheet.swift       # 学期配置编辑器（含节次列表编辑）
├── TableSelectSheet.swift       # 表选择（同 SourceFilterSheet 型）
├── TimetableMenu.swift          # FAB 管理菜单
└── ImportExport.swift           # fileImporter/fileExporter + 预览确认接线
ios/OpenJWC/Features/Me/Settings/TimetablePrefsView.swift   # 四开关 + 迷你预览
```

组合根：`AppEnvironment` 增 `timetable: TimetableStore`（观察启动）与 `timetableService`；`AgentRuntime.makeLoop()` 注入 timetable source（D-5）；`AppShellView` 占位 tab 替换为 `TimetableRootView`。

**关键交互还原细节**（实施对照表，源自 Android 源码）：块按压缩放 0.97/拖拽 1.06（spring ≈800/0.5）；浮层起始于原尺寸 spring(700/0.85) 长到整列 × 全课高；落位/回弹 220ms easeInOut + scale 1.06→1.00；数据反映撤浮层（onChange + 1s 兜底）；`isReady` 后推迟一帧渲染重网格（`Task.yield` 等价 `withFrameNanos`）；拖动中块 alpha 0（本周）/ 0（非本周同 id）；空槽 tap → 新建预填；稳定回调防级联重组（SwiftUI 视图值语义天然稳定）。

## D-10 测试策略

| 层 | 用例族 | 数量级 |
|---|---|---|
| core 单测 | `stableJavaHash` 已知值对照（ASCII/中文/混合/空串，与 Java 计算值硬编码断言） | 4–6 |
| core 单测 | `visibleSegments` 泳道：无冲突/两道/三道传递组/拖动露层/裁剪拆段 | 5–7 |
| core 单测 | `resolveDropTarget`：中心定列/上缘定节/越界/冲突/整块出界 | 5–6 |
| core 单测 | `isConflicting`：五条件组合边界 | 4–5 |
| core 单测 | `TimetableJson.parseExternal`：weeks 三态/`"null"` 清理/行丢弃/推断（weeks≥16、周末、13 节扩展）/rows 缺失与空异常 | 8–10 |
| core 单测 | `buildExport`：可选字段省略/空表 nil/导出↔导入回环 | 3–4 |
| core 单测 | `TimetableService`：建表即切换/删当前表切换/导入事务（tableId 重映射）/upsert 不清课程（既有锁定复跑） | 4–6 |
| core 单测 | `formatWeekRule`：每周/单/双/区间压缩 | 4–5 |
| app 手验 | 拖拽全流程（起拖动画/落位/回弹/冲突提示）、周滑页同步、四开关即时性、导入导出文件闭环、Me 预览 | 6a/6b 各一批 |

验收命令沿用交接文档：`swift test --skip AllSourcesSmoke --skip ScriptAcceptance --skip LLMKeyAcceptance`（基线 71/16 → 预期 ~100+/16+），`xcodegen generate` + `xcodebuild -scheme OpenJWC -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO build`。

## D-11 实施节奏（复制阶段 5 的 5a/5b 模式）

- **6a = core 纯函数 + 网格 + 数据流 + 拖拽**（TimetableLayout/TimetableJson/Service + Store + GridView/BlockView/HeaderRow + 拖拽全动画链）→ 验收点：网格渲染正确、拖拽调课全流程手验
- **6b = 编辑器 + 表管理 + 导入导出 + Agent + Me 设置**（EditCourse/TableConfig/TableSelect/Menu/ImportExport + makeLoop 接线 + TimetablePrefsView）→ 验收点：编辑/管理/导入导出闭环、聊天可问课表
