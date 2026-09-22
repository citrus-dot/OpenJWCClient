# 阶段 6（课表）调研交接文档

> **交接对象**：下一会话（实施 agent）。**任务**：阶段 6 课表 OpenSpec 立案已完成并经用户评审通过（方案 b），下一会话从实施阶段起接手（6a/6b 节奏见下文第六节），**实施前再次跑 §5 快捷命令核验环境基线**。
> **前置必读**（按序）：`docs/ios-port-roadmap.md`（进度真源，§8 阶段 6 小节）→ 本文档 → `openspec/changes/ios-timetable/` 四件套（`proposal.md` / `specs/timetable/spec.md` / `design.md` / `tasks.md`）+ 调研附录 `research-webview-import.md`（仅记录有效派别①③④，未来升级 WebView 时直接读此文档）→ Android 真源目录（需要时对照）。
> **当前进度**（2026-09-22 17:40 更新）：阶段 0–5 已完成归档（资讯/对话/日报/我的四 tab 转正，仅课程表占位）；离线 `swift test --disable-sandbox --skip AllSourcesSmoke --skip ScriptAcceptance --skip LLMKeyAcceptance` 71/16 全绿；HEAD `85a6800`（≥ `dd15868`，工作区干净）。**阶段 6 OpenSpec 立案完成 + 评审通过 + 方案 b（JSON 文件导入先行、WebView 延后另立 change）已定，未实施**。
>
> **ai-memory 交接快照**：本会话结束前已用 ai-memory `memory_handoff_begin` 写入跨会话 handoff，SessionStart 钩子会在下一会话自动注入；如未见自动注入块，调用 `memory_handoff_list` 查询并 `memory_handoff_accept` 领取。
> **memory 同步（2026-09-22）**：`/Users/orange/OpenJWC_4ios/.workbuddy/memory/2026-09-22.md` 含阶段 6 立案全程记录；`MEMORY.md`（项目长期）按需更新；用户级 `~/.workbuddy/MEMORY.md` 未变。

## 一、调研范围（Android 真源）

Android 课表是全项目最大 UI 模块，`app/src/main/java/org/openjwc/client/ui/timetable/` 下 36 文件：

| 子目录 | 文件 | 调研要点 |
|---|---|---|
| `view/` | `TimetableScreen.kt` | 页面骨架：周切换、工具栏、与 MainScreen 的挂载方式 |
| `view/grid/` | `TimetableGrid.kt`、`CourseBlock.kt`、`CourseLayer.kt`、`GridBackgroundLayer.kt`、`TimeIndicatorLine.kt`、`PeriodLabel.kt` | **周视图网格核心**：lane/segment 布局算法（重叠课程分道）、节次坐标计算、时间指示线、背景层；这是移植难点核心 |
| `view/state/` | `TimetableUiState.kt` | UI 状态机（周次选择/拖拽态/选中课程） |
| `view/components/` | `TimetableHeader.kt`、`TimetableOverlayHost.kt`、`TopAppBar.kt` | 表头（周次条）、overlay 宿主机制 |
| `view/sheets/` | `CourseDetail.kt`、`TableSelectSheet.kt` | 课程详情弹层（iOS 可用 sheet）；表选择（iOS 已有 SourceFilterSheet 同型参考） |
| `edit/` | `TimetableActionSheet.kt`、`EmptyGuidePlaceholder.kt` | 编辑动作入口与空态引导 |
| `edit/courses/` | `EditCourseDialog.kt`、`CourseBasicInfoFields.kt`、`CourseTimeSection.kt`、`CourseWeekRuleSection.kt`、`CustomWeekPickerDialog.kt`、`ColorPickerRow.kt`、`DeleteCourseDialog.kt` | 课程编辑器全集：基本信息/时间/周次规则/颜色 |
| `edit/tables/` | `TableConfigDialog.kt`、`TableSelectSheet`、`TimePickerDialog.kt`、`WeekSlider.kt`、`PeriodHeader.kt`、`PeriodEditItem.kt`、`ConfigSwitchRow.kt`、`DataSelectionCard.kt`、`DeleteTableDialog.kt` | 表配置：节数/时间/开关/周滑块 |
| `load/` | `ImportWebViewScreen.kt` | **WebView 导入**（教务系统抓课表）——iOS 端建议 WKWebView 等价实现或裁剪，需调研决策 |
| `utils/` | `TimetableGridUtils.kt`、`WeekRuleUiExt.kt` | 布局工具与周次文案 |

配套数据层（iOS 已有，无需重做，调研时确认接口匹配即可）：
- `Packages/OpenJWCCore/Sources/OpenJWCCore/Database/DAO/TimetableDao.swift`（TableMetadataRecord + CourseRecord；**REPLACE 已禁用**，一律 upsert，单测锁定）
- `Agent/Corpus.swift` 的 `GrdbTimetableSource`（学期周次解析 `currentWeek` 已实现并有单测）

## 二、必须回答的调研问题（产出进 design.md）

1. **周视图布局**：Android `TimetableGrid` 的 lane/segment 算法细节（冲突课程如何分道、高度按节次均分还是自定义时间）；iOS 端用 SwiftUI 原生 `Layout` protocol / Canvas / 混合 ZStack+GeometryReader 哪种最合适（给出取舍）。
2. **拖拽交互**：`TimetableDragState` + `a8146ed`/`e547b9a`（上游 2026-09 新提交：长按拖拽 + resize 动画）的交互细节；iOS 用 `draggable`/`DropDelegate` 还是自管手势；弹性落点 + overlay 动画的还原口径。
3. **学期周次**：确认 `GrdbTimetableSource.currentWeek`（周一为首、越界 nil）与 Android `weekOf` 语义一致；课表页周次条的范围展示规则。
4. **数据流**：表列表/当前表/课程的观察方式（沿用阶段 5 的 ValueObservation 单闭包模式）；`SettingsStore.currentTableId`（0=nil）的联动。
5. **Agent 工具接入**：`AgentRuntime.makeLoop()` 目前只传 `GrdbNoticeCorpus`——接入课表后补 `GrdbTimetableSource`（AgentTools 已支持，spec 自动暴露课表工具组）；确认无需其它接线。
6. **WebView 导入裁剪决策**（**2026-09-22 已决策方案 b**）：Android `ImportWebViewScreen` 用 WebView 登录教务系统抓课表 HTML → `TableParserUtils` 解析。iOS 三选一 (a) WKWebView 等价移植 / (b) JSON 导入导出先行 / (c) 完全裁剪——**Nironta 拍板选 b**：JSON 导入导出（上游 `e44bf35`）覆盖换机/双端互通/A 备份核心价值，且与 a 共用全部解析与预览代码（升级零返工）；a 的增量收益伴随账号依赖手验成本与 ehall 改版脆弱性。详见 `design.md` D-6 决策结论 + D-6-补 调研补遗（GitHub 主流方案四派对照，未来升级优先方案 d=WebView+LLM 读页面文字）。
7. **样式**：课程块配色对齐 Android `CourseColors.kt`（MD3 动态色 `f970dcc`）；iOS 26 玻璃就地采用口径（D-8：网格容器/工具栏）。

## 三、约束与纪律（承接全程）

- **约束**（详见 memory `project_memory.md`）：原生组件 + Liquid Glass（iOS 26 `if #available`，18 回退 ultraThinMaterial）；功能不缺失（D10）；on-device 分支；用户 GitHub 身份（citrus-dot）。
- **流程**：OpenSpec 立案（proposal→specs→design→tasks→**用户评审批准后才可实施**）；里程碑处 commit+push（中文提交信息）；`swift test` 全绿是每次提交的底线。
- **实施节奏参考**：阶段 5 的 5a/5b 两批验收模式被用户认可，阶段 6 可复制（如 6a=视图网格+数据流，6b=编辑器+导入导出）。
- **环境**：Xcode 26.6 / Tahoe 26.6.2 / 模拟器 iPhone 17（iOS 26.5）；验收命令 `xcodebuild -scheme OpenJWC -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO build`。

## 四、交付物

1. `openspec/changes/ios-timetable/` 四件套（proposal/specs/design/tasks），行为契约逐条对齐 Android 真源（发现偏差须在 spec 中标注修正理由）——**2026-09-22 已完成，`openspec validate ios-timetable` 通过**。
2. `openspec validate ios-timetable` 通过 ——**已确认**。
3. 向用户提交评审（NotifyUser），**不自行开工实施** ——**已完成，方案 b 已拍板，未实施**。

## 五、快捷命令

```bash
cd /Users/orange/OpenJWC_4ios/Packages/OpenJWCCore
# 注意：SwiftPM 内部 sandbox-exec 在某些执行环境不可用，需 --disable-sandbox
swift test --disable-sandbox --skip AllSourcesSmoke --skip ScriptAcceptance --skip LLMKeyAcceptance 2>&1 | grep "Test run with"
# 期望：✔ Test run with 71 tests in 16 suites passed

git -C /Users/orange/OpenJWC_4ios log --oneline -5   # 确认 HEAD ≥ dd15868（当前 85a6800）
git -C /Users/orange/OpenJWC_4ios status --short      # 确认工作区干净（实施期间允许有改动）
```

## 六、下一会话接手事项（实施阶段）

1. **接手流程**：读 ai-memory handoff 块（或 `memory_handoff_list` 领取）→ 跑 §5 快捷命令核验基线 → 读 `openspec/changes/ios-timetable/tasks.md` 起手实施。
2. **实施节奏**（复制阶段 5 的 6a/6b 模式）：
   - **6a**（tasks 组 1–4）：core 纯函数（`TimetableLayout`/`TimetableJson`/`TimetableService`）+ 周视图网格 + 数据流 + 拖拽调课全动画链 → 验收点：网格渲染正确 + 拖拽调课全流程手验。**6a 完成后停下等 Nironta 手验再开 6b**。
   - **6b**（tasks 组 5–8）：课程详情/编辑器 + 表管理 + JSON 导入导出 + Agent 接线 + Me 课表设置 → 验收点：编辑/管理/导入导出闭环、聊天可问课表。
   - **组 9**：归档收尾（全量测试绿 + `xcodebuild` 模拟器构建通过 + roadmap 更新 + `openspec archive ios-timetable -y` + commit/push 中文提交信息）。
3. **关键风险点**：
   - 拖拽落位动画的状态时序是全案最复杂交互点（浮层撤除依赖数据回读 + 1s 兜底）—— 6a 验收必须本机手验。
   - Swift `String.hashValue` 按进程随机播种 → 必须直译 Java `String.hashCode()` 多项式 ×31 算法为 `stableJavaHash`，否则同名课程每次启动变色、双端配色不一致。design D-7 已强调。
4. **WebView 导入不在本案范围**：6b 完成后若要补，应另立 `ios-timetable-webview-import` change，调研补遗（design D-6-补）建议优先方案 d=WebView+LLM 读页面文字而非方案 a=硬编码 extractor。
5. **不擅自范围扩张**：阶段 7（平台集成）的事项（WidgetKit 小组件 / BGTaskScheduler 后台调度 / 通知）不在本案。
