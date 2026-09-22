# Tasks: ios-timetable

> 交付节奏（复制阶段 5 被认可的模式）：**6a = 组 1–4**（core 纯函数 + 周视图网格 + 数据流 + 拖拽调课）先验收；**6b = 组 5–8**（编辑器 + 表管理 + 导入导出 + Agent/Me 接线）再验收。组 9 归档收尾。对应 spec scenarios 见各组标注。

## 1. core 纯函数：布局算法（spec：周视图网格/拖拽调课；design D-1/D-2/D-8）
- [ ] 1.1 `TimetableLayout.findContinuousBlocks`（连续节次拆段，直译 TimetableGridUtils）
- [ ] 1.2 `TimetableLayout.visibleSegments`（本周占用裁剪 + 拆段 + `assignLanes` 传递分组贪心分道；draggingId 排除占位）
- [ ] 1.3 `TimetableLayout.resolveDropTarget`（中心定列/上缘定节 roundToInt + coerce/越界与冲突判 nil）
- [ ] 1.4 `TimetableLayout.isConflicting`（同表/异 id/同天/节段重叠/周次交集，直译 isConflictingWith）
- [ ] 1.5 `TimetableLayout.formatWeekRule`（每周/单周/双周/自定义区间压缩文案）
- [ ] 1.6 单测：泳道族（含拖动露层、裁剪拆段、三道传递组）+ 落点族 + 冲突边界族 + 文案族

## 2. core 纯函数：JSON 与配色（spec：JSON 导入导出/课程编辑器；design D-7）
- [ ] 2.1 `stableJavaHash`（Java String.hashCode 直译）+ 已知值对照单测（ASCII/中文/混合/空串）
- [ ] 2.2 `courseBackgroundColors` 16 色 ARGB 常量 + 确定性配色 `colorIndex(for name:)`
- [ ] 2.3 `TimetableJson.parseExternal`：weeks 三态提取（数字数组/字符串数组/`"1-16周(单)"`/单数字）、`"null"` 清理、无效行丢弃、totalWeeks/hasWeekend/maxPeriod 推断、13 节自动扩展（21:30–22:15）、表名 `(MM-dd HH:mm)` 后缀、rows 缺失/空 throw
- [ ] 2.4 `TimetableJson.buildExport`：规范化键、可选字段非空才写、2 空格缩进、无表/无课返回 nil
- [ ] 2.5 单测：解析族（≥10 用例）+ 导出族 + 导出↔导入回环（颜色一致性）

## 3. core 服务：TimetableService（spec：课表管理/JSON 导入导出；design D-8）
- [ ] 3.1 `createTable`（落库 → setCurrentTable → 周同步）+ `updateTable`（周数收缩 clamp 当前周）
- [ ] 3.2 `deleteTable`（删当前 → 切剩余首表 → 周同步；无剩余周 = 1）
- [ ] 3.3 `switchTable` + `saveCourse`/`removeCourse`
- [ ] 3.4 `confirmImport`（事务：saveTable → tableId 重映射 → upsertCourses → setCurrentTable → 周 = 1）
- [ ] 3.5 单测：建表即切换/删表切换链/导入重映射/既有 upsert 不清课程锁定复跑

## 4. 周视图 + 数据流 + 拖拽【6a 里程碑：验收点——网格渲染 + 拖拽调课全流程手验】（spec：周视图网格/网格背景/时间指示线/周切换/长按拖拽；design D-1/D-2/D-3/D-4/D-9）
- [ ] 4.1 `TimetableStore`：单闭包 ValueObservation 多表组装（tables/current/courses 快照 + removeDuplicates）、currentWeek 状态机（表切换重算/内部更新标志）、分钟对齐 activePeriodIndex Timer、displayPrefs 读取
- [ ] 4.2 `AppEnvironment` 装配 + `AppShellView` 课表 tab 转正（替换 PlaceholderTabView）
- [ ] 4.3 `TimetableRootView`：顶栏（表名 → 表选择入口、「第 N 周」胶囊）、`TabView(.page)` 周翻页双向同步（settledPage ↔ currentWeek；内部无动画/外部动画）、isReady 推迟一帧、空态引导（导入/新建）
- [ ] 4.4 `TimetableGridView`：背景 Canvas（网格线 + 活跃行高亮 + 空槽 tap 定位）、节次标签列（HH:mm、showPeriodTime 开关）、`CourseBlockView`（本周全列宽/非本周泳道淡显、isShort 内容规则、按压缩放）
- [ ] 4.5 `TimetableHeaderRow`：周日期（weekStart 归一周一）、今天胶囊高亮、午夜刷新
- [ ] 4.6 时间指示线：节内分钟插值/节间贴下节上缘/界外隐藏/60s 刷新 + showTimeline 开关
- [ ] 4.7 拖拽全链路：`TimetableDragState`（@Observable）+ 长按 sequenced 手势 + 浮层（原尺寸 spring 长到整列 × 全课高、拖动 1.06）+ 落位/回弹 220ms + 数据反映撤浮层（onChange + 1s 兜底）+ 拖动露下层重排
- [ ] 4.8 手验脚本清单：拖拽有效落位/冲突回弹/越界回弹/周滑页/今天高亮/指示线/非本周泳道

## 5. 课程详情与编辑器【6b 起点】（spec：课程详情/课程编辑器；design D-7/D-9）
- [ ] 5.1 `CourseDetailSheet`：非本周徽标 + 地点/周次文案/节次段 + 备注分组 + 编辑/删除入口
- [ ] 5.2 删除课程确认
- [ ] 5.3 `EditCourseSheet`：基本信息字段（name 必填）、星期选择、起止节（startPeriod + duration）、周次规则（每周/单/双/自定义网格）、16 色板（名称驱动自动选色 + 手动改色锁定）、备注
- [ ] 5.4 冲突实时提示（1/2/≥3 门文案）+ 禁用保存；空槽点击预填天/节进入新建

## 6. 表管理（spec：课表管理/学期配置编辑器；design D-8/D-9）
- [ ] 6.1 `TimetableMenu`（FAB/工具栏菜单）：切表/表配置/加课/导出/文件导入/建空表/删表（无 AddShortCut）
- [ ] 6.2 `TableSelectSheet`：列表 + 当前高亮 + 新建 + 导入入口（同 SourceFilterSheet 型）
- [ ] 6.3 `TableConfigSheet`：表名非空校验、开学日期（归一周一）、周数滑块 ≤30、显示周末开关、节次列表（增 末节+10min/45min、删 ≥1、改起止）+ 时间冲突校验禁存 + 节数低于在用警告；导入预览复用（maxPeriodInUse 提示）
- [ ] 6.4 删表确认 + 删除当前表自动切换剩余首表

## 7. JSON 导入导出（spec：JSON 导入导出；design D-6 选 b 时范围即此）
- [ ] 7.1 导出：`fileExporter`（表名净化 `\ / : * ? " < > |` 空格 → `_`，空回退 `timetable`，`.json`；无课提示）
- [ ] 7.2 导入：`fileImporter`（application/json）→ `parseExternal` → 预览确认（复用 TableConfigSheet）→ `confirmImport` 事务
- [ ] 7.3 解析失败提示具体原因（rows 缺失/空/读文件失败）；导入错误 Toast/alert 一次性消费
- [ ] 7.4 手验：导出→导入回环（颜色/课程一致）、与 Android 端导出文件互通

## 8. Agent 接线 + Me 课表设置（spec：Agent 课表工具接线/课表显示设置；design D-5）
- [ ] 8.1 `AgentRuntime.makeLoop()` 注入 `GrdbTimetableSource`（一行 + 注释）
- [ ] 8.2 `TimetablePrefsView`：四开关（showTimeline/showDate/showPeriodTime/showNonCurrentWeek，读写 UserSettings）+ 迷你网格预览实时反映
- [ ] 8.3 手验：聊天问「我周三有什么课」触发 get_courses_on；设置开关即时生效

## 9. 归档收尾
- [ ] 9.1 全量测试绿（`swift test` 离线全跑 + 外网套件单跑）+ `xcodebuild` 模拟器构建通过
- [ ] 9.2 roadmap 更新（阶段 6 完成小节 + §5 产出清单）+ 6a/6b 手验记录
- [ ] 9.3 `openspec archive ios-timetable -y` + commit/push（中文提交信息）
