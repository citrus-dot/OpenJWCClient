# 阶段 6（课表）调研交接文档

> **交接对象**：下一会话（调研 agent）。**任务**：完成阶段 6 课表的专项调研 + OpenSpec 立案四件套，评审通过后可继续实施。
> **前置必读**（按序）：`docs/ios-port-roadmap.md`（进度真源，§8 阶段 6 小节）→ 本文档 → Android 真源目录。
> **当前进度**：阶段 0–5 已完成归档（资讯/对话/日报/我的四 tab 转正，仅课程表占位）；离线 `swift test` 71/16 全绿；HEAD `dd15868`（fork `citrus-dot/OpenJWCClient`，分支 `feat/on-device-ai`）。
>
> **memory 同步（2026-09-22）**：`project_memory.md` 约束与经验已更新至阶段 5 后状态；`20260922/topics.md` 含阶段 4/5 全程记录。接手后先跑第五节快捷命令核验环境。

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
6. **WebView 导入裁剪决策**：Android `ImportWebViewScreen` 用 WebView 登录教务系统抓课表 HTML → `TableParserUtils` 解析。iOS 方案三选一：(a) WKWebView 等价移植（保功能完整）；(b) JSON 导入导出先行，WebView 导入延后；(c) 完全裁剪。**倾向 (b)**（D10 功能不缺失 vs 实现成本平衡，JSON 导入导出 Android 已有 `e44bf35`），但需调研 Android JSON 格式后由用户拍板。
7. **样式**：课程块配色对齐 Android `CourseColors.kt`（MD3 动态色 `f970dcc`）；iOS 26 玻璃就地采用口径（D-8：网格容器/工具栏）。

## 三、约束与纪律（承接全程）

- **约束**（详见 memory `project_memory.md`）：原生组件 + Liquid Glass（iOS 26 `if #available`，18 回退 ultraThinMaterial）；功能不缺失（D10）；on-device 分支；用户 GitHub 身份（citrus-dot）。
- **流程**：OpenSpec 立案（proposal→specs→design→tasks→**用户评审批准后才可实施**）；里程碑处 commit+push（中文提交信息）；`swift test` 全绿是每次提交的底线。
- **实施节奏参考**：阶段 5 的 5a/5b 两批验收模式被用户认可，阶段 6 可复制（如 6a=视图网格+数据流，6b=编辑器+导入导出）。
- **环境**：Xcode 26.6 / Tahoe 26.6.2 / 模拟器 iPhone 17（iOS 26.5）；验收命令 `xcodebuild -scheme OpenJWC -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO build`。

## 四、交付物

1. `openspec/changes/ios-timetable/` 四件套（proposal/specs/design/tasks），行为契约逐条对齐 Android 真源（发现偏差须在 spec 中标注修正理由）。
2. `openspec validate ios-timetable` 通过。
3. 向用户提交评审（NotifyUser），**不自行开工实施**。

## 五、快捷命令

```bash
cd /Users/orange/OpenJWC_4ios/Packages/OpenJWCCore
swift test --skip AllSourcesSmoke --skip ScriptAcceptance --skip LLMKeyAcceptance 2>&1 | grep "Test run with"
# 期望：✔ Test run with 71 tests in 16 suites passed

git -C /Users/orange/OpenJWC_4ios log --oneline -5   # 确认 HEAD ≥ dd15868
```
