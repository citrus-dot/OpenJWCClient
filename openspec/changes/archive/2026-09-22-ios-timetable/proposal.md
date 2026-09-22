# Proposal: ios-timetable

## Why
阶段 0–5 已完成归档：资讯/对话/日报/我的四个 tab 转正，离线 71/16 测试全绿，仅课程表 tab 仍为占位（`AppShellView` 中 `PlaceholderTabView(title: "课程表", phase: 7)`）。课表是 Android 端全项目最大 UI 模块（`ui/timetable/` 37 文件，含周视图网格、长按拖拽调课、课程/课表双层编辑器、WebView 教务导入、JSON 导入导出）。不补齐此模块，iOS 端无法达成 D10「功能不缺失」对照基准，Agent 的课表工具组（`get_timetable`/`list_timetables`/`get_courses_on`/`find_course`）也无数据可读。

## What Changes
- **core 纯函数层新增**（可单测，UI 无关）：
  - `TimetableLayout`：lane/segment 泳道算法直译（非本周课程按本周占用裁剪 → 连续块拆分 → 传递性分组贪心分道）、落点解算（水平中心定列 / 上边缘定节次 / 冲突与越界判 null）、课程冲突判定 `isConflicting`（同表 + 异 id + 同天 + 节次区间重叠 + 周次交集）、周次文案 `formatWeekRule`（每周/单周/双周/自定义区间）
  - `TimetableJson`：导入解析（宽容：weeks 接受数字数组/字符串数组/`"1-16周(单)"`、teacher/location 的 `"null"` 清理、无 weeks 或无 name 行丢弃、totalWeeks/hasWeekend/maxPeriod 推断）+ 导出序列化（规范化键，可选字段非空才写）；**确定性配色用 Java 语义 String.hashCode 直译**（保证与 Android 同名同色，Swift `hashValue` 每进程随机不可用）
  - 稳定色板 `courseBackgroundColors` 16 色 ARGB 常量（对齐 Android `Color.kt`）+ 课程块配色（seed → container/content 双态，见 design D-4 简化决策）
- **core 服务层新增**：`TimetableService`（表 CRUD 编排：创建即切换、更新、删除当前表自动切换剩余首表、`currentWeek` 同步、导入落库事务 tableId 重映射）
- **app 课表 tab 全量**（替换占位）：
  - 周视图网格：背景 Canvas 网格线 + 节次标签列 + 时间指示线（60s 刷新、节内按分钟插值、节间贴下节上缘、界外隐藏）+ 周日期表头（今天高亮、跨午夜刷新）+ 本周课程全列宽块 + 非本周课程泳道淡显（四开关控制）
  - 周切换：整周横滑翻页（page 式 pager），settledPage ↔ currentWeek 双向同步（内部更新无动画、外部动画滚动）；表名/「第 N 周」顶栏
  - 长按拖拽调课：浮层原位放大动画（spring）、弹性落点 220ms tween、冲突/越界回弹、数据反映后再撤浮层（1s 兜底）
  - 课程详情 sheet（非本周徽标 + 地点/周次/节次 + 备注 + 编辑/删除）；空槽点击 → 新建课程编辑器预填天/节
  - 课程编辑器（基本信息/星期节次/周次规则/16 色选择/备注 + 冲突实时提示与冲突课列表）；课程删除确认
  - 表管理：FAB 菜单（切表/表配置/加课/导出/导入/建空表/删表）、表选择 sheet、表配置编辑器（名称/开学日期归一周一/周数滑块 ≤30/显示周末/节次增删改 + 时间冲突校验 + 节数低于在用警告）、删表确认
  - JSON 文件导入导出（`fileImporter`/`fileExporter`，导入走统一预览确认对话框）
  - 空态引导（导入 / 新建）
- **app Me 设置**：课表设置页（四显示开关 + 迷你预览，读已有 `UserSettings` 字段，持久化零新增）
- **Agent 接线**：`AgentRuntime.makeLoop()` 补传 `timetable: GrdbTimetableSource(db:)`（`AgentTools` 课表工具组已就绪，构造注入即自动暴露 spec）
- **WebView 教务导入**：**本案不含**（决策：方案 b = JSON 文件导入先行、WebView 导入延后另立 change，详见 design D-6；调研补遗：GitHub 主流方案的更优吸纳点见 D-6 末段「调研补遗」，未来升级时可优先考虑方案 d=WebView+LLM 读页面文字而非硬编码 extractor 脚本）

## 调研依据（2026-09-22，Android 真源逐文件 + 主流实现对照）
- Android 真源 37 文件全部通读：`TimetableGrid`/`CourseLayer`/`TimetableDragState`（布局与拖拽机制）、`TimetableViewModel`（数据流/导入导出编排）、`TableParserUtils`（JSON 宽容解析）、`CourseRepository`（导入推断规则）、`EditCourseViewModel`（编辑器状态与冲突规则）、`TableConfigViewModel`（表配置校验）、`ImportWebViewScreen` + `timetable_extractor.js`（WebView 导入桥）、`CourseColors`（MD3 tonal 配色）、`TimetablePrefsScreen`/`TimetablePreview`（Me 侧设置）。
- 上游提交核验：本工作区 HEAD（`92ae0d5` 克隆）已含 `a8146ed`（长按拖拽）与 `e547b9a`（拖拽浮层尺寸动画）终态，无需 git 考古，源码即终态。
- iOS 已有资产核验：`TimetableDao` 全方法齐备（REPLACE 已禁用，upsert 单测锁定）；`GrdbTimetableSource.currentWeek`（周一为首/越界 nil/clamp）与 Android `calculateCurrentWeek` 语义一致且有单测；`UserSettings` 已含 `currentTableId`/`showTimeline`/`showDate`/`showPeriodTime`/`showNonCurrentWeek`/`courseReminderEnabled` 全部字段；`AgentTools` 已定义课表四工具与可选 `timetable` 注入参数。
- 主流实现对照：SwiftUI 拖拽浮层用自管 `DragGesture` + `zIndex`（系统 `draggable`/`DropDelegate` 是跨视图拖放语义，拿不到原位 overlay 与落位动画）；GRDB 单闭包 ValueObservation 多表组装（阶段 5 已验证模式）；SwiftUI `TabView(.page)` 对应 `HorizontalPager`；`Animatable` 对应 `Animatable`（Compose）做宽度/落位动画。
- 关键移植陷阱发现：**Swift `String.hashValue` 按进程随机播种**，Android 确定性配色基于 `String.hashCode()`（稳定多项式）——必须直译 Java hashCode 算法，否则同名课程每次启动变色、且与 Android 端颜色不一致。

## Non-goals
- **课程提醒 / 小组件（WidgetKit）/ BGTaskScheduler 后台调度** → 阶段 7 平台集成
- **WebView 教务导入** → **延后另立 change**（决策：方案 b；调研补遗详见 design D-6，未来升级优先考虑方案 d=WebView+LLM 读页面文字而非硬编码 extractor 脚本，跨校通用、抗 ehall 改版）
- Android `AddShortCut` 桌面快捷方式动作 → iOS 无对应概念，裁剪（spec 标注）
- 深层动画定制（Liquid Glass 全覆盖复查、Dynamic Type、xcstrings 5 语言）→ 阶段 8 打磨
- 主题色选择器 / 背景图 / 通知 / 代理设置 → 阶段 8 或按 Android 侧对应模块另行评估

## Impact
- core：新增 3 个纯函数文件 + 1 个服务文件（约 600–800 行）+ AgentTools 接线一行；既有 71 测试必须保持绿，新增单测约 25–35 个（布局算法/JSON 解析/冲突判定/hashCode 一致性/服务编排）
- app：新增 `Features/Timetable/` 目录（约 12–16 个视图/Store 文件）+ Me 设置新增课表设置页；`AppShellView` 课表 tab 转正
- 风险：拖拽落位动画的状态时序（浮层撤除依赖数据回读）是全案最复杂交互点，拆组实施 + 专项手验；lane 算法纯函数化先行 + 单测锁定，降低网格重组风险
