# OpenJWC-Client

东南大学教务资讯的开源客户端。本仓库同时承载两个平台的客户端：

| 平台 | 状态 | 说明 |
|---|---|---|
| **Android** | 功能完整，上游活跃开发中 | Jetpack Compose 构建，目录 `app/` |
| **iOS / iPadOS** | 移植进行中（域层 + 资讯 UI 已完成） | SwiftUI 构建，目录 `ios/` + `Packages/OpenJWCCore/` |

- 上游仓库：[OpenJWC/OpenJWCClient](https://github.com/OpenJWC/OpenJWCClient)（Android 真源）
- iOS 移植进度与决策记录：[`docs/ios-port-roadmap.md`](docs/ios-port-roadmap.md)（进度真源）
- 当前移植分支：`feat/on-device-ai`

## 快速开始

### Android

使用 Android Studio 打开本仓库，编译即可。

### iOS（要求 macOS 26 + Xcode 26.6）

```bash
# 1. 生成 Xcode 工程（工程文件不入库，改动 project.yml 后需重新生成）
cd ios && xcodegen generate && open OpenJWC.xcodeproj

# 2. 选择 iPhone 模拟器，Cmd+R 运行
#    模拟器无需签名；真机 / My Mac (Designed for iPhone/iPad)
#    需在 Xcode → Settings → Accounts 登录免费 Apple ID（签名 7 天有效，可无限续签）

# 3. 域层单元测试（SwiftPM，独立于 App 可跑）
cd Packages/OpenJWCCore && swift test
```

技术栈：SwiftUI（最低部署目标 iOS 18.0，iOS 26 Liquid Glass 玻璃效果就地采用）· GRDB（SQLite/WAL）· JavaScriptCore（脚本宿主）· SwiftSoup（HTML 解析）· MarkdownUI（正文渲染）。

## 特性

### Android（现有全量功能）

1. AI Chat:
   - **深度理解**：教务处通知太长？AI 助你快速提炼要点，化繁为简。
   - **上下文感知**：支持点击“+”号关联特定资讯作为背景信息，拒绝“幻觉”，让回答更精准。
   - **对话管理**：采用侧边抽屉式列表，直观管理历史会话。
2. 私有化资讯驱动：自主选择数据源获取教务处动态。配合高亮提醒，确保重要通知绝不遗漏。
3. 现代视觉语言：适配 Material Design 3。旨在通过简洁、优雅、流畅的交互，构建快速、直观的用户操作体验。
4. 全方位个性化定制：
   - **视觉**：动态色彩主题、自定义背景图片，让 App 独一无二。
   - **性能与网络**：支持自定义服务器、代理配置及资讯高亮时效，完全掌握数据的主动权。

### iOS（移植路线，按阶段推进）

- ✅ **域层**（阶段 1–3）：GRDB 数据库（Room v14 终态 schema 对齐）、JavaScriptCore 脚本宿主（与 Android QuickJS 同一份脚本资产零修改复用）、LLM 客户端（OpenAI 兼容 SSE）、Agent 循环与 11 个工具、Keychain 密钥存储
- ✅ **资讯 UI**（阶段 4）：五 tab 导航壳、栏目页签 + 自适应网格资讯流、分页预载、下拉刷新抓取（进度/日志/取消面板）、源筛选、收藏、Markdown 详情、图片查看器、通知深链
- ⏳ 后续：聊天 + 日报 + 设置中心（阶段 5）→ 课表（阶段 6）→ 后台抓取与通知（阶段 7）→ 打磨发布（阶段 8）

完整决策链（D1–D10）与逐阶段验收记录见 [`docs/ios-port-roadmap.md`](docs/ios-port-roadmap.md)。

## 架构

### Android

```
             【 表现层 (UI Layer - Jetpack Compose) 】
           ┌──────────────────────────────────────────┐
           │  Activities & Screens (Composables)      │
           └────────────────────┬─────────────────────┘
                                │ (1) 用户操作 (Events)
                                ▼
            【 状态层 (ViewModel Layer - AAC) 】
           ┌──────────────────────────────────────────┐
           │  ViewModels (NewsVM, SettingsVM, etc.)   │ <──┐
           └────────────────────┬─────────────────────┘    │
                                │ (2) 请求数据 (Calls)      │ (3) 响应数据
                                ▼                          │     (Flows/States)
            【 领域/数据层 (Repository Layer) 】            │
           ┌──────────────────────────────────────────┐    │
           │  Repositories (News, Settings, Chat)     │ ───┘
           └──────────┬───────────────────────┬───────┘
                      │                       │
           (4) 读取/写入│                 (4) 网络请求
                      ▼                       ▼
    【 本地数据源 (Local) 】         【 远程数据源 (Remote) 】
  ┌────────────────────────┐      ┌─────────────────────────┐
  │ ● DataStore (Settings) │      │ ● NetClient (OkHttp)    │
  │ ● Room DB (Cache)      │      │ ● API Service (Retrofit)│
  └────────────────────────┘      └─────────────────────────┘
```

### iOS

```
【 App 层 ios/ 】SwiftUI + @Observable
  AppShellView（五 tab）→ NewsListView / FavoriteListView / NewsDetailView
  AppEnvironment（组合根）· AppRouter（深链路由）· ReactiveStore（ValueObservation 桥接）
                                      │
                                      ▼
【 域层 Packages/OpenJWCCore 】SwiftPM 包，纯 Swift、单元测试覆盖
  Database（GRDB 迁移 + DAO）· Scripting（JavaScriptCore 宿主 + 六桥 + 超时竞速）
  NewsCrawl（播种 + 逐源抓取编排 actor）· LLM（OpenAI 兼容 SSE）· Agent（预算循环 + 11 工具）
  Settings（UserDefaults 双域 + Keychain）
                                      │
           （本地 SQLite / Bundle 内置脚本资产 / 直连 LLM API，无自建服务端）
```

两平台行为对齐基准：Android 端代码为真源，iOS 逐模块直译（SQL、脚本契约、警告文案逐字对齐）。

## 数据源脚本

资讯抓取由本地脚本驱动，内置东南大学教务处（默认订阅）及 30 余个院系/学院官网数据源，
也可以在「设置 → 资讯数据源」里侧载自己的脚本（`fetchNotices()` 契约，宿主提供
`http` / `dom` / `util` / `params` / `console` / `report` 桥）。

**同一份脚本资产双平台复用**：Android 跑在 QuickJS、iOS 跑在 JavaScriptCore（均为 ES2020 级引擎，脚本零修改）。

- 脚本格式与 API 参考：[`docs/script-format.md`](docs/script-format.md)
- 内置脚本（双平台共用真源）：[`app/src/main/assets/sources/`](app/src/main/assets/sources/)（iOS 以 folder reference 打包同份资产）
- 改造计划（Android 端）：[`PLAN.md`](PLAN.md)

## 仓库结构

```
├── app/                        # Android 客户端（上游真源）
├── Packages/OpenJWCCore/       # iOS 域层 SwiftPM 包（数据库/脚本宿主/LLM/Agent）
├── ios/                        # iOS App（XcodeGen 工程：编辑 project.yml 后执行 xcodegen generate）
├── docs/
│   ├── ios-port-roadmap.md     # iOS 移植决策链与进度真源（新会话接手必读）
│   └── script-format.md        # 数据源脚本契约
├── openspec/                   # iOS 功能变更规格（OpenSpec 工作流：proposal/specs/design/tasks）
└── PLAN.md                     # Android 端去云端改造计划
```

## 用户协议

欢迎使用 OpenJWC（以下简称“本产品”）。本协议是您与 OpenJWC 开发者之间就使用本产品所订立的法律协议。请您在安装、配置或使用本产品前，认真审阅本协议的所有条款。一旦您完成客户端配置或使用相关服务，即表示您已充分理解并自愿接受本协议的全部约定。

### 第一条 服务性质与范围

本产品是一款为用户提供教务资讯聚合、RAG（检索增强生成）教务问答及资讯投稿功能的辅助工具。

本产品采用私有化部署架构。开发者仅提供软件代码及技术方案，不直接运营服务器。您所连接的服务是由具体的部署者（可能是您个人、学校社团或第三方组织）提供的，开发者不对部署者提供服务的可用性、合法性承担责任。

本产品的名称、图标及源代码的版权归开发者所有。用户对本软件的使用不代表开发者转让了除许可证规定之外的其他任何权利。

### 第二条 账号与服务使用规范

用户在客户端配置服务器信息时，需确保所填写的服务器 BaseURL 及账户信息准确有效。

用户不得利用本产品进行任何非法活动，包括但不限于爬取涉及个人隐私的敏感信息、传播违法有害信息、攻击教务系统等。

用户在进行资讯投稿时，应保证内容的真实性、合法性及非侵权性。严禁发布谣言、诽谤、煽动性言论或未经授权的版权内容。

用户应妥善保管自己的访问凭证。因用户保管不当导致的账号被盗用或数据泄露，由用户自行承担责任。

### 第三条 服务免责声明

**第三方关联性**：OpenJWC 与东南大学教务处及校方其他机构不存在任何官方隶属或合作关系。所有通过本产品获取的资讯仅供参考，教务事项的最终结论请以学校官方渠道发布的信息为准。

**服务可用性**：由于教务网站可能进行架构调整或维护，本产品无法保证 100% 的服务在线率。因不可抗力、网络波动或校方系统变动导致的服务中断或资讯获取失败，开发者不承担赔偿责任。

**AI 准确性**：AI 问答功能基于现有知识库生成，可能存在事实偏差或理解错误。对于任何基于 AI 回复而做出的学业决策，用户需自行承担风险，建议关键信息进行交叉核对。

### 第四条 私有化部署责任边界

本产品作为遵循 **MIT 许可证**的开源工具发布。对于部署者在使用过程中产生的任何法律风险、数据合规问题及安全隐患，由部署者自行承担全部责任。

原开发者不参与也不干预私有服务器的运行维护。若您在使用过程中认为部署者的管理行为损害了您的合法权益，请直接与该服务器的管理员进行协商或根据相关法律途径维护权益。

### 第五条 协议修订与终止

开发者有权根据法律法规变化或产品功能升级对本协议进行修订。更新后的协议将在产品内发布，即时生效。若您在协议变更后继续使用本产品，视为接受修订后的条款。

若用户违反本协议规定，开发者及部署者有权在不事先通知的情况下限制或终止其访问权限。

### 第六条 争议解决

本协议的订立、执行及解释均适用中华人民共和国法律。

如用户与原开发者发生争议，应通过友好协商解决；协商不成的，任何一方均可向开发者所在地有管辖权的人民法院提起诉讼。

### 第七条 联系与反馈

如您对本协议有任何疑问或建议，欢迎通过项目开源平台提交反馈。对于具体的服务器运行、数据存储等问题，请直接联系为您提供服务的私有化部署管理员。

## 许可证

MIT License
