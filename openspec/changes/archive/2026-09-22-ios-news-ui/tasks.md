# Tasks: ios-news-ui

## 1. App 壳重建（spec：五 tab 导航壳）
- [x] 1.1 重写 `ios/project.yml`：iOS 18.0、本地包依赖 OpenJWCCore、删 GRDB 直连、删空 OpenJWCTests 引用、资产 folder reference
- [x] 1.2 `xcodegen generate` 重建工程，Mac destination 空壳可编译运行（占位五 tab）
- [x] 1.3 `AppEnvironment` 组合根 + `AppRouter` 路由状态（覆盖场景「启动落在资讯 tab」「占位 tab 不崩溃」）

## 2. core public 化（design：public 化清单）
- [x] 2.1 按最小集清单 public 化既有类型，语义零改动
- [x] 2.2 `swift test` 保持 40/10 全绿

## 3. 源播种（spec：内置数据源播种）
- [x] 3.1 `SourceRegistry.syncBuiltIns()`：Bundle 资产枚举 → manifest 解析 → upsert；默认仅订阅 seu-jwc（场景「首次启动播种」）
- [x] 3.2 幂等：不覆盖用户订阅态（场景「二次启动幂等」）；已删除内置源装回且默认不订阅并清除删除记录（对齐 Android syncBuiltIns，spec 已修正）
- [x] 3.3 单测：空库播种/幂等/删除装回（临时文件 DB）
- [x] 3.4 App 启动路径接入（Environment 初始化时调用）

## 4. 抓取编排（spec：抓取编排）
- [x] 4.1 `NewsCrawlService`（actor）：逐订阅源执行脚本流程，`AsyncStream<CrawlEvent>` 进度/日志事件（场景「手动触发全量抓取」）
- [x] 4.2 防重入 + 取消传播 + `lastRunAt` 回写（失败亦回写 error，对齐 Android；场景「防重入」「用户取消」）
- [x] 4.3 资讯落库走 NoticeDao（补抓判定/contentVersion 对齐）
- [x] 4.4 单测：事件序/防重入/取消/运行结果回写（假脚本资产）
- [x] 4.5 `CrawlCoordinator`：app 侧事件流消费 → UI 状态

## 5. 资讯流列表（spec：资讯流列表）
- [x] 5.1 栏目 tab（可滚动）+ 每栏目独立分页状态机（场景「栏目状态互不干扰」）
- [x] 5.2 网格卡片：title/date/摘要/星标/fresh 高亮（场景「fresh 日期高亮」），自适应列数
- [x] 5.3 分页 LIMIT/OFFSET 20 + 倒数第 2 项预载 + isEnd（场景「首次进入栏目加载」）
- [x] 5.4 下拉刷新 → CrawlCoordinator；进度面板（进度/日志/取消）（场景「用户取消」UI 侧）
- [x] 5.5 noticeCount 观察驱动已载栏目重读（spec：响应式数据桥接 场景「抓取后计数自动更新」）

## 6. 源筛选（spec：源筛选）
- [x] 6.1 底部 sheet 单选（全部 = null + 逐源订阅态）（场景「筛选单一源」「切回全部」）
- [x] 6.2 切换重置栏目与分页状态并重载

## 7. 收藏（spec：收藏）
- [x] 7.1 星标切换（卡片 + 详情页双入口）（场景「收藏并查看」）
- [x] 7.2 收藏页：ValueObservation 响应式列表、单项删除、清空确认（场景「清空收藏」）

## 8. 详情 + 图片 + 深链（spec：详情页 / 通知深链消费）
- [x] 8.1 详情页 MarkdownUI 渲染（场景「打开详情」）+ 按 id 恢复滚动位置
- [x] 8.2 图片全屏查看器：缩放/分享/失败重试（场景「查看图片」）
- [x] 8.3 附件与详情 URL 交系统浏览器（场景「附件外链」）
- [x] 8.4 `handleDeepLink(userInfo:)`：news_detail/news/timetable 路由 + 无效 id 降级 + 冷热启动一致（场景「点单条资讯通知」「无效 id 降级」）

## 9. 响应式桥接与验收（spec：响应式数据桥接）
- [x] 9.1 `ReactiveStore`：三条 ValueObservation 挂载/释放管理（场景「收藏状态跨页同步」）
- [x] 9.2 **39 源全量离线冒烟**：JSC 上逐脚本 manifest 解析 + 列表抓取回归，逐源记录失败/告警对齐 Android（roadmap 阶段 4 验收扩展）——39 源 0 致命失败，累计 2787 条，35 警告源均为附件/PDF 型正文暂缺类非致命告警（与 Android 同源）
- [ ] 9.3 Mac destination 全场景手验：按 spec 12 个 Scenario 逐条过并记录（自动化已验：五 tab 壳/启动落资讯/播种 39 源仅订阅 seu-jwc/栏目渲染/空态；交互场景待用户手验）
- [x] 9.4 `swift test` 全绿（50/13：基线 40 + 播种 3 + 编排 6 + 冒烟 1）→ `openspec validate` 通过
