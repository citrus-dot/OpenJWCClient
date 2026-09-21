# Design: ios-news-ui

## 架构总览

```
ios/OpenJWC (app target, iOS 18.0, SwiftUI)
├── App/OpenJWCApp.swift          # @main、深链路由入口、通知注册（阶段 7 前仅消费）
├── App/AppEnvironment.swift      # 组合根：DB/Settings/CrawlService 单例装配
├── Navigation/AppShellView.swift # TabView 五 tab + 深链路由 + 收藏页压栈
├── Router/AppRouter.swift        # @Observable 路由状态（tab 选择、详情栈、查看器）
└── Features/News/
    ├── NewsStore.swift           # @Observable：栏目状态机 + 分页 + 筛选（命令式查询）
    ├── ReactiveStore.swift       # ValueObservation → @Observable 桥（3 条观察）
    ├── CrawlCoordinator.swift    # 抓取事件流 → UI 状态（进度/日志/取消）
    ├── NewsListView.swift        # 栏目 tab + 网格 + 下拉刷新
    ├── NewsCardView.swift
    ├── SourceFilterSheet.swift
    ├── FavoriteListView.swift
    ├── NewsDetailView.swift      # MarkdownUI 渲染 + 图片入口
    ├── ImageViewer.swift         # 全屏缩放查看器
    └── PlaceholderTabView.swift  # 四个未实现 tab 占位

Packages/OpenJWCCore 新增
└── Sources/OpenJWCCore/NewsCrawl/
    ├── SourceRegistry.swift      # syncBuiltIns 播种（资产枚举+manifest upsert+幂等）
    └── NewsCrawlService.swift    # actor：逐源编排、AsyncStream<CrawlEvent>、防重入、取消
```

## 关键设计决策

### D-1 组合根与访问级别
`AppEnvironment` 在 app 进程内装配一次：`DatabaseProvider.open()` → DAO → `NewsCrawlService` → stores。阶段 3 的 internal 类型（Agent/LLM/Scripting 层）本阶段仅 public 化 **资讯路径所需最小集**（清单见「public 化清单」）；Agent/LLM 留给阶段 5 再扩。

### D-2 ValueObservation 桥接（roadmap §6-1 坑的解法）
不标注 `-> ValueObservation<[T]>` 返回类型，改用官方推荐链式模式，避免 `where Reducer == ValueReducers.Fetch<Value>` 约束炸编译：

```swift
let observation = ValueObservation.tracking { db in try NoticeDao.favorites(db) }
    .removeDuplicates()
observation.observe(in: queue) { favorites in ... }   // 回调内更新 @Observable store
```

三条观察（sources、favorites、noticeCount）统一收在 `ReactiveStore`，`observation.start()` 持有 observation 值防止释放；视图销毁时 cancel。

### D-3 Markdown 渲染选型：MarkdownUI
Android 用 mikepenz multiplatform-markdown-renderer（M3 主题 + Coil3 + 代码高亮）。iOS 候选对比：
- **MarkdownUI（gonzalezreal）**：SwiftUI 原生、主题可定制、表格/代码块/图片支持完整、社区最活跃 → **选中**。
- 原生 `AttributedString`（markdown 解析）：表格不支持，HtmlToMarkdown 产物含大量表格 → 排除。
- Web 渲染（WKWebView）：保真但破坏原生滚动/深链/图片查看体验 → 排除。
图片加载用 AsyncImage + 自定义缓存（资讯图片量为低-中，不引第三方图片库，阶段 8 视情况再加）。

### D-4 抓取编排线程模型
`NewsCrawlService` 为 `actor`，事件用 `AsyncStream<CrawlEvent>` 产出（UI 侧 `for await` 驱动进度面板）。每源抓取复用 `JavaScriptHost` 既有 worker 竞速设计（跑完即弃），iOS 侧 JSC 调用天然离开主线程。取消 = `Task.cancel()` 传播到脚本执行间隙检查点。防重入 = actor 内 `isRunning` 状态位。

### D-5 内置源资产打包
`app/src/main/assets/sources/*.js`（37 个）在 iOS app target 以 **folder reference 打包**（project.yml sources 指到资源目录），`SourceRegistry` 用 `Bundle` 枚举。core 测试侧用测试 bundle 副本，不依赖 app 资产。

### D-6 深链载体
iOS 无 Android Intent extras，对齐语义映射：通知 `userInfo` 键沿用 `destination` / `news_id` 字符串值。`AppRouter.handleDeepLink(userInfo:)` 冷启动（通知启动项）与热到达共用；路由动作在首帧渲染后执行（避免 NavigationStack 未挂载丢失）。

### D-7 网格列数
对齐 Android（按宽度 1/2/3 列）：`LazyVGrid` + `GridItem(.adaptive)`，用 `windowScene` 尺寸断点换算；Designed-for-iPhone 的 Mac 窗口可缩放，走 resize 即时重排。

## public 化清单（阶段 3 internal → public，最小集）

| 文件 | 类型/成员 | 用途 |
|---|---|---|
| `ScriptTypes.swift` | `ScriptManifest`、`ScriptNotice`、解析入口 | SourceRegistry 播种 + 抓取结果 |
| `JavaScriptHost.swift` | `JavaScriptHost` 类与 `CrawlParams` | NewsCrawlService 驱动 |
| `Database/DAO/*.swift` | 各 DAO 查询方法与 record | Store/列表/收藏/详情查询 |
| `Models/*.swift` | 8 组 record 类型 | UI 直接消费 |
| `Settings/SettingsStore.swift` | `UserSettings`/`LlmPrefs` | freshDays 等读取 |
| `Corpus.swift` | `NoticeCorpus` | 抓取落库复用 DAO 路径 |

不改语义、不加新 API（NewsCrawl 新增除外）；40 项既有测试必须保持绿。

## project.yml 变更

- `deploymentTarget.iOS: "18.0"`（D6 修正）
- 删除 app 对 GRDB 的直接依赖（经 OpenJWCCore 传递）；新增本地包依赖 `OpenJWCCore`（relativePath `../Packages/OpenJWCCore`）
- 资产：`OpenJWC/Resources/Sources`（folder reference）+ Info.plist 不变；`OpenJWCTests` target 延后到有 iOS 单测需求时再立（本次删除空引用，避免 xcodegen 报错）
- 生成物 `OpenJWC.xcodeproj` 已在 .gitignore，不提交

## 边界与错误处理

- 空库首启：播种 → 空列表态（「下拉获取资讯」引导）。
- 抓取中断网：逐源失败事件入日志面板，已完成源保留；`lastRunAt` 仅成功源更新。
- 详情内容缺失（contentVersion 落后）：显示基础字段 + 提示，不阻塞浏览。
- 图片加载失败：占位图 + 重试按钮。

## 测试策略

- **core 单测**（macOS，Swift Testing）：SourceRegistry 幂等/默认订阅/deletedSourceIds 跳过；NewsCrawlService 防重入/取消/事件序/lastRunAt 更新（假脚本资产 + 临时文件 DB，复用既有测试基建）。目标：新增后基线 40 → 约 48+ 全绿。
- **UI 验收**：Mac destination 手验 spec 场景清单（见 tasks 组 9），路由/深链用本地通知触发验证。
