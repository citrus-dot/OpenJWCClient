# news-ui Specification（delta）

> 行为契约以 Android 真源为准（`app/src/main/java/org/openjwc/client/`），以下为 iOS 端对齐口径。

## ADDED Requirements

### Requirement: 五 tab 导航壳
App SHALL 提供五个顶层 tab：Chat、DailyReport、News、Timetable、Me（顺序对齐 Android `MainTab`）。未实现阶段的 tab SHALL 显示占位内容（名称 + 「阶段 N 实现」提示），不影响已实现 tab 功能。

#### Scenario: 启动落在资讯 tab
- **WHEN** 用户冷启动 App
- **THEN** 默认选中 News tab（对齐 Android `currentTab` 默认值）
- **AND** 其余四个 tab 均可切换且显示占位或已实现内容

#### Scenario: 占位 tab 不崩溃
- **WHEN** 用户切换到 Chat / DailyReport / Timetable / Me 任一占位 tab
- **THEN** 显示占位视图，无任何数据层调用

### Requirement: 内置数据源播种
首次运行（sources 表为空）时，App SHALL 从内置资产枚举 `sources/*.js` 解析 manifest（@id/@name/@labels/@domains/@scheduleMinutes）并 upsert 进 sources 表，默认仅订阅 `seu-jwc`；已记录于 `deletedSourceIds` 的内置源 SHALL 重新装回但默认不订阅，并清除该删除记录（对齐 Android `SourceRegistry.syncBuiltIns`）。再次启动 SHALL 幂等（不重复插入、不覆盖用户订阅状态）。

#### Scenario: 首次启动播种
- **WHEN** App 在空库上首次启动
- **THEN** sources 表包含全部内置源，仅 `seu-jwc` subscribed = true
- **AND** 每个源带正确的 id/name/labels/domains

#### Scenario: 二次启动幂等
- **WHEN** 用户已手动改订阅状态后再次启动
- **THEN** 订阅状态保持用户值，不重置为默认

### Requirement: 抓取编排
core 层 SHALL 提供抓取编排服务：按订阅源逐个执行脚本抓取流程（fetchList→fetchContent），产出进度事件流（开始/逐源完成/日志/结束），全程可取消且防重入；完成后更新源 `lastRunAt`，资讯经 `NoticeDao` 落库（含补抓判定与内容版本）。

#### Scenario: 手动触发全量抓取
- **WHEN** 用户在资讯页下拉刷新
- **THEN** 依次抓取所有订阅源，界面展示进度与日志
- **AND** 新资讯落库后列表自动出现新内容

#### Scenario: 防重入
- **WHEN** 抓取进行中用户再次下拉刷新
- **THEN** 不并发启动第二次抓取（UI 同步禁用入口）

#### Scenario: 用户取消
- **WHEN** 用户在进度面板点取消
- **THEN** 剩余源不再抓取，已落库结果保留，界面回到就绪态

### Requirement: 资讯流列表
资讯页 SHALL 按栏目（label）分栏展示：顶部可滚动栏目 tab，每栏目独立网格列表（宽度自适应 1/2/3 列）。卡片字段：标题（最多 2 行）、日期（yyyy-MM-dd，`freshDays` 内高亮）、摘要（contentText 最多 3 行）、收藏星标。分页 SHALL 为 LIMIT/OFFSET=20，滚动到倒数第 2 项触发下一页，返回数 < 20 判定到底。

#### Scenario: 首次进入栏目加载
- **WHEN** 用户选中某栏目 tab 且该栏目未加载
- **THEN** 显示前 20 条（`listByLabel` 语义：置顶/稳定排序），滑动到底自动追加下一页

#### Scenario: 栏目状态互不干扰
- **WHEN** 用户在多个栏目 tab 间切换
- **THEN** 各栏目保留各自的列表位置与分页进度

#### Scenario: fresh 日期高亮
- **WHEN** 卡片日期距今天 ≤ freshDays（默认 21）
- **THEN** 日期以主色容器高亮显示

### Requirement: 源筛选
资讯页 SHALL 提供源筛选入口（顶栏标题 + 下拉箭头），点开底部 sheet 单选列表：首项「全部数据源」（sourceId = null），其余逐源显示「名称 · 订阅状态」。切换后 SHALL 立即重置栏目与分页状态并按新筛选重载。

#### Scenario: 筛选单一源
- **WHEN** 用户在 sheet 中选择某个源
- **THEN** 所有栏目列表只显示该源的资讯

#### Scenario: 切回全部
- **WHEN** 用户选择「全部数据源」
- **THEN** 列表恢复全部资讯，排序稳定

### Requirement: 收藏
用户可对任意资讯卡片或详情页切换收藏星标；独立收藏页 SHALL 响应式展示全部收藏（`observeFavorites`），支持单项删除与清空（清空需确认弹窗），点收藏卡进入详情。

#### Scenario: 收藏并查看
- **WHEN** 用户点亮某卡片星标后打开收藏页
- **THEN** 该资讯出现在收藏列表中

#### Scenario: 清空收藏
- **WHEN** 用户点击清空并确认
- **THEN** 收藏表清空，列表即时变空

### Requirement: 详情页
详情页 SHALL 渲染 `contentText` 的 Markdown 正文（对齐 HtmlToMarkdown 产物语义：标题/列表/表格/链接/图片）。图片点击进入全屏查看器（可缩放、可分享）。附件 URL 与「在浏览器打开」SHALL 交系统浏览器处理。返回列表后再次进入同一资讯 SHALL 恢复原滚动位置。

#### Scenario: 打开详情
- **WHEN** 用户点击资讯卡片
- **THEN** 进入详情页显示 Markdown 正文、来源与日期

#### Scenario: 查看图片
- **WHEN** 用户点击正文中的图片
- **THEN** 全屏查看器打开该图，可捏合缩放并退出

#### Scenario: 附件外链
- **WHEN** 用户点击附件链接
- **THEN** 系统浏览器打开该 URL（不做应用内下载）

### Requirement: 通知深链消费
App SHALL 消费本地通知 `userInfo`（键对齐 Android extras：`destination` ∈ {news_detail, news, timetable}，news_detail 另附 `news_id`）：news_detail → 切到 News tab 并按 id 打开详情；news → 仅切 News tab；id 无效 SHALL 降级为仅切 tab。冷启动与前台到达 SHALL 行为一致。

#### Scenario: 点单条资讯通知
- **WHEN** 用户点击携带 news_detail + 有效 news_id 的通知
- **THEN** App 切到资讯 tab 并直接打开该资讯详情

#### Scenario: 无效 id 降级
- **WHEN** news_id 在库中不存在（如已清理）
- **THEN** 仅切到资讯 tab，不崩溃、不开空白详情

### Requirement: 响应式数据桥接
源列表、收藏列表、资讯总数 SHALL 通过 GRDB ValueObservation 持续驱动 UI（源列表/收藏变更、抓取落库后计数变化自动反映）；分页列表查询 SHALL 保持命令式一次性查询。观察 SHALL 在视图生命周期内自动启停，不泄漏。

#### Scenario: 抓取后计数自动更新
- **WHEN** 抓取落库新资讯
- **THEN** 资讯总数观察者自动收到新值（UI 依据它重读已载栏目）

#### Scenario: 收藏状态跨页同步
- **WHEN** 用户在详情页取消收藏后返回
- **THEN** 收藏页与列表卡片的星标态即时一致
