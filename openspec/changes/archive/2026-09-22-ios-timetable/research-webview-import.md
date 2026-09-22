# WebView 教务导入方案调研附录

> **调研日期**：2026-09-22  
> **调研对象**：「WebView 教务导入」是否还有比 Android 现有 `ImportWebViewScreen`（WKWebView + 硬编码 `timetable_extractor.js` 调 ehall 内部接口路径）更优秀的方案  
> **调研来源**：GitHub / Gitee / 掘金 / Apple App Store / 个人项目主页  
> **关联文档**：`design.md` D-6（决策结论：本案方案 b）+ D-6-补（指针与本附录摘要）  
> **结论一句话**：本案 6b 仍按方案 b（JSON 文件导入）实施；未来升级到 WebView 时**优先方案 d** 而非方案 a；方案 e 作为阶段 8 候选。

## 调研范围说明

本次仅记录**有效方案**（对本案决策或未来升级有参考价值的派别）：

| 派别 | 是否纳入本附录 | 理由 |
|---|---|---|
| ① WebView 注入硬编码脚本派 | **纳入** | 本案 Android 端的现状基线，作为升级前后对比基线 |
| ② 云端脚本可更新派 | **不纳入** | OpenJWC 是单体 iOS App，运维独立 server 仓库 + Docker Compose 不符合架构边界，明确不予吸纳，无需详细记录 |
| ③ AI 截图/文件识别派 | **纳入** | 阶段 8「AI 增强导入」候选，未来扩展的轻量补充 |
| ④ WebView + LLM 读页面文字派 | **纳入** | 未来升级 WebView 时优先考虑的方向，最有价值的吸纳点 |

---

## ① WebView 注入硬编码脚本派（现状基线）

### 代表项目
- **本案 Android `ImportWebViewScreen`**（`app/src/main/java/org/openjwc/client/ui/timetable/load/ImportWebViewScreen.kt` + `assets/timetable_extractor.js`）
- **ScaratP/GetSchedule**（Kotlin + Compose，GitHub）—— 内置 WebView 自动登录 + 自动擷取，本派典型实现
- **川大 ScuTimetable**（CSDN 实践文章）—— 同思路的校园特定实现

### 机制
1. 真实浏览器（Android `WebView` / iOS `WKWebView`）加载教务系统登录页（OpenJWC 当前为 `http://ehall.seu.edu.cn/appShow?appId=4770397878132218`）
2. 用户手动登录（凭证不进 App 进程）
3. 用户进入课表页后，App `evaluateJavascript(timetable_extractor.js)` 注入脚本
4. 脚本调教务**内部 API**（如 `xskcb.do` / `xnxqcx.do`），用同步 XHR 拉结构化 JSON
5. 字段映射（KCM/SKJS/JASMC/SKXQ/KSJC/JSJC/ZCMC/KCH/JXBQH → 规范化 rows）
6. `window.AndroidBridge.sendData(JSON)` / iOS 等价 `window.webkit.messageHandlers.iosBridge.postMessage(...)` 桥回传
7. App 走统一预览确认（`pendingImport → TableConfigDialog`）

### 优势
- 抓**真源数据保真**（直接调教务内部 API，结构化 JSON 输出）
- 登录走真实浏览器，**合规**（凭证不经 App 进程、不存本地）
- 已有 Android 端完整实现可参考

### 劣势
- 脚本依赖特定 ehall 接口路径与字段名（KCM/SKJS/JASMC 等），**前端改版即失效**
- 脚本绑死单校（OpenJWC 当前是 SEH ehall 专属，换校需重写）
- WebView 在 iOS 端需 ATS 例外（`NSAllowsArbitraryLoadsInWebContent`，因 ehall 多为 http 站点）
- 模拟器验证受校园网/教务账号可得性制约

### 对本案的吸纳点
- **本案 6b 不实现此派别**（方案 a）——已决策延后
- 现状 `timetable_extractor.js`（65 行）作为 Android 端资产保留参考，未来升级到方案 a 时桥调用改 `window.webkit.messageHandlers.iosBridge.postMessage`，保留 `AndroidBridge` 守卫以兼容 Android 端脚本复用

---

## ③ AI 截图/文件识别派（阶段 8 候选）

### 代表项目
- **Meet 课程表**（App Store，重庆 Zhenyue Liuguang）—— AI 截图/文字识别 + 教务直连（已适配部分学校）+ PDF 上传三种导入方式
- **YIClass**（Flutter 跨平台，GitHub `wykwey/YIClass`）—— 多 AI 服务支持（OpenAI/Claude/Gemini/DeepSeek）+ 图片/CSV/Excel/文字 AI 识别 + JSON 导入导出
- **next_class**（Web PWA + Flask 后端，GitHub `fangguan233/next_class`）—— 通义千问 LLM 解析 + AI 冲突自我修正 + 6 位分享码导入
- **析课**（`yedaoai.com`）—— LLM 识别 Excel/PDF/图片，导出 ICS 给系统日历，**明确反对在 App 内登录教务系统导入**，主张隐私优先（无需注册、不存任何个人信息）

### 机制
1. 用户在系统浏览器/教务系统截图，或导出 PDF/Excel，或粘贴课表文本
2. 多模态 LLM 识别课程名/节次/地点/周次/教师
3. 结构化数据进入预览页，用户核对后一键保存
4. 部分项目（next_class）含「AI 冲突自我修正」——导入时自动检测并尝试修复课程冲突

### 优势
- **跨校通用零适配**——不依赖任何教务系统接口或 DOM 结构
- **零 WebView 依赖**——无 ATS 例外负担、无 ehall 改版风险
- **隐私优先**（析课派的明确主张）——不在 App 内登录教务，不收集凭证
- 多 AI 服务可选（YIClass 同时支持 OpenAI/Claude/Gemini/DeepSeek），用户自备 key

### 劣势
- 用户需额外操作（截图/导出文件/粘贴文本）
- 多模态 LLM 调用成本（按次计费，如 Meet 课程表「AI 导入按次数计费点数」）
- 复杂排版识别率不稳定（析课项目自承「不同学校课表差异较大，识别可能不完整」）
- 部分项目要求用户配置 AI 服务 API Key（YIClass、next_class 自托管），门槛高

### 对本案的吸纳点
- **本案 6b 不实现**——阶段 6 主线是课表核心移植，AI 截图识别属增强功能
- **阶段 8「AI 增强导入」候选**：可作为「跨校通用导入」的轻量补充，但需多模态模型选型与成本评估
- **复用本案 b 路径的资产**：AI 输出可走 `TimetableJson.parseExternal` 兼容解析（解析宽容、weeks 三态提取），直接复用 `TableConfigSheet` 预览链路 + `TimetableService.confirmImport` 落库事务，零新增 UI 资产
- **模型路由复用**：建议复用 `AgentTools` 现有多模型路由（DashScope/Qwen、DeepSeek、OpenRouter），不引入额外 AI 服务依赖

---

## ④ WebView + LLM 读页面文字派（未来升级优先方向）

### 代表项目
- **SleepDown 课程表**（`sleepdownschedule.cn`）—— 液态玻璃视觉 + 多方式导入 + 今日助手 Agent；导入分四路：AI 导入（文件/图片/文本整理）+ **AI 教务导入**（读教务页面文字送 LLM 整理）+ 教务导入（已适配学校直连）+ 手动录入

### 机制
1. 用户在 App 内 WebView 登录教务系统（真实合规，凭证不进 App 进程）
2. 用户导航到课表页后，App 不注入硬编码 extractor 脚本
3. App 调 `evaluateJavaScript("document.body.innerText")` 抓取**渲染后的页面可见文字**（DOM 渲染结果，非 API 调用）
4. 抓取的页面文字送多模态/文本 LLM 整理为结构化课程
5. LLM 输出走预览页确认，用户核对后保存

### 优势
- **跨校通用**——不依赖任何教务接口路径，只读 DOM 渲染后的可见文字
- **抗 ehall 改版**——DOM 文字结构比 API 路径稳定（教务升级 UI 但文字布局通常不变）
- 登录走真实浏览器，**合规**（凭证不经 App 进程）
- 多模态 LLM 仅做后处理，不在登录链路上，延迟可接受
- 与本案 b 路径共用全部解析与预览代码——升级零返工

### 劣势
- WebView 仍是 ATS/mixed content 例外负担（同方案 a）
- LLM 调用成本与延迟（每次导入一次多模态调用）
- LLM 输出不可直接落库，**必须预览确认**（用户核对环节不可省）
- 复杂 DOM 文字结构（如多门课挤在同一单元格）可能让 LLM 漏识别

### 对本案的吸纳点（未来升级实现要点）

**未来若另立 `ios-timetable-webview-import` change 实施方案 d，按以下链路落地**：

1. **WKWebView 装配**：`WKWebView` + `WKNavigationDelegate.didFinish` 钩子 + ATS 例外（`NSAllowsArbitraryLoadsInWebContent`，ehall 多为 http 站点）
2. **抓取**：`webView.evaluateJavaScript("document.body.innerText")` 抓取渲染后可见文字
3. **LLM 整理**：建议复用 `AgentTools` 现有模型路由（DashScope/Qwen、DeepSeek、OpenRouter），不引入额外 AI 服务依赖；提示词约束输出为兼容 `TimetableJson.parseExternal` 的 JSON 结构
4. **解析复用**：LLM 输出走 `TimetableJson.parseExternal`（本案 6b 已实现）——解析宽容、weeks 三态提取、`"null"` 清理、无效行丢弃、totalWeeks/hasWeekend/maxPeriod 推断
5. **预览复用**：走本案 `TableConfigSheet` 预览确认链路
6. **落库复用**：走 `TimetableService.confirmImport` 事务（saveTable → tableId 重映射 → upsertCourses → setCurrentTable → 周 = 1）
7. **零新增 UI 资产**：除 WebView 容器页外，全靠本案 b 路径打好的底子

**关键设计决策**（留给未来 change 评审）：
- 抓取的页面文字是否需要分段（避免超长 LLM 输入）？建议先抓全文，按字符数（如 > 16k）再分段
- LLM 提示词是否需要校特定 few-shot？建议 zero-shot 起步，失败再补校特定示例
- 是否在 WebView 内检测到课表页自动触发抓取？建议**不自动**，保留 FAB「看到课表点我」手动触发，与 Android 端交互一致

---

## 整体结论与建议

| 时间窗 | 推荐方案 | 理由 |
|---|---|---|
| **本案 6b（阶段 6）** | 方案 b（JSON 文件导入） | 阶段 6 主线是课表核心移植，三派都需额外复杂度，不匹配 |
| **未来升级 WebView 时** | 方案 d（WebView + LLM 读页面文字） | 跨校通用、抗 ehall 改版、合规、与本案 b 共用全部解析与预览代码、零返工 |
| **阶段 8（AI 增强导入）** | 方案 e（AI 截图识别） | 完全无 WebView 依赖的跨校通用轻量补充；需多模态模型选型与成本评估 |

**不吸纳**：方案 a（硬编码 extractor 脚本）在方案 d 出现后已无优势；方案 ②（DawnCourse 云端脚本）不符合单体 App 架构边界。

**关键复用资产**（本案 6b 实施后留给未来升级用的底子）：
- `TimetableJson.parseExternal`——LLM 输出天然落点
- `TableConfigSheet`——预览确认链路
- `TimetableService.confirmImport`——落库事务
- `AgentTools` 模型路由——LLM 调用基础设施
