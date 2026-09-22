# Proposal: ios-news-ui

## Why

路线图阶段 4（Tahoe 已就位、D9 落定 Xcode 26.6，无阻塞）。阶段 1–3 的 OpenJWCCore 域层（40 测试基线）至今没有任何 UI 消费者；本阶段交付第一个可用 app 界面——资讯流全流程，在 Mac 原生（`My Mac (Designed for iPhone)`）运行验证。

**关键缺口（调研发现）**：core 包只有脚本宿主/DAO 积木，**不存在抓取编排层**（Android 真源 `SourceRunner.crawl` + `SourceRegistry.syncBuiltIns` 无对应物）。资讯 UI 的下拉刷新依赖它，必须在本阶段补齐。

## What Changes

1. **App 壳重建**（`ios/`）：xcodegen 重生成 target；部署目标按 D6 改回 **iOS 18.0**（现占位 project.yml 误写 26.0）；接 OpenJWCCore 本地包依赖；五 tab 导航壳（Chat/DailyReport/News/Timetable/Me，未实现 tab 占位）。
2. **core 新增抓取编排层** `NewsCrawl` 模块：内置源播种（对齐 `SourceRegistry.syncBuiltIns`，枚举 bundled `sources/*.js` → manifest 解析 → upsert，默认仅订阅 `seu-jwc`）+ 逐源抓取编排（对齐 `SourceRunner`，防重入/可取消/进度事件/更新 lastRunAt）。
3. **资讯流列表**：栏目 label 顶部 tab + 网格卡片（title 2 行/date/摘要 3 行/星标/fresh 高亮）、LIMIT/OFFSET 分页 20、倒数第 2 项预载、下拉刷新→抓取→完成刷新。
4. **源筛选**：底栏 sheet + 单选（首项「全部数据源」= sourceId null），切换清空栏目与分页状态。
5. **收藏**：星标切换 + 独立收藏页（响应式列表、单项删除、清空带确认）。
6. **详情页**：Markdown 正文渲染（选型 **MarkdownUI**，见 design）、图片全屏查看器、附件与详情 URL 交系统浏览器、按 id 恢复滚动位置。
7. **通知深链**：本地通知 `userInfo` 对齐 Android extras 语义（`destination`=news_detail/news/timetable + `news_id`），冷/热启动均可路由；id 无效降级为仅切 tab。
8. **响应式桥接**：源列表/收藏/资讯总数三条 GRDB `ValueObservation` → `@Observable` store；分页列表保持命令式一次性查询（对齐 Android 形状）。

## Non-Goals

- 聊天 + 日报 + Me 设置中心（阶段 5；含 motto 格言/LLM/来源编辑器——组织调研确认的功能补全项，届时另立案）。
- 课表（阶段 6）、后台调度与通知发布（阶段 7）、Liquid Glass 全覆盖（阶段 8，但本阶段 UI 实现时**就地采用** `if #available(iOS 26.0, *)` 玻璃效果，不推迟到最后）。
- **云端版功能（D10 已拍板裁剪）**：投稿、设备绑定/解绑、连接自建服务器（Go 后端 v1/v2 17 端点）——均为云端版历史功能，Android feat 分支已删除（本地 Kotlin 代码零命中验证），iOS 对齐 feat 分支口径同步裁剪。域层 Repository 协议已天然预留未来扩展空间。
- 数据源侧载/管理 UI（新增自定义源）、抓取间隔等设置项编辑 UI（沿用默认值）。

## Impact

- **代码**：`ios/` 全量重建；`Packages/OpenJWCCore` 新增 `NewsCrawl/` 模块 + 既有类型 public 化（清单见 design）；`ios/project.yml` 重写。
- **测试**：core 新增 NewsCrawl 单测（临时目录 DB + 假脚本资产）；UI 以 Mac 原生手验，验收标准见 spec 场景。
- **风险**：GRDB ValueObservation API 坑（roadmap §6-1，用官方推荐模式规避）；SwiftUI 在 Designed-for-iPhone 窗口的网格列数适配；JSC 抓取在 iOS 进程内的线程模型（复用现有 task-group 竞速设计）。
