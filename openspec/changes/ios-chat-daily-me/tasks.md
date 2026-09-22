# Tasks: ios-chat-daily-me

> 交付节奏（用户拍板）：**5a = 组 1–4**（core 扩展 + 聊天全量）先验收；**5b = 组 5–8**（日报 + Me）再验收。组 9 归档收尾。

## 1. core public 化第二批（design D-4）
- [ ] 1.1 `AgentTypes`/`AgentLoop`/`AgentTools`（run/answer/displayName/summary 面）public 化
- [ ] 1.2 `LlmClient`（协议 + 流事件）+ `LlmKeyStore` public 化
- [ ] 1.3 `ChatDao` 全方法 + `Models/Chat.swift` record + `DailyReportDao` public 化
- [ ] 1.4 `swift test` 保持 51 全绿

## 2. core 新增域层（design D-1/D-2/D-5/D-6）
- [ ] 2.1 AgentLoop 跨帧 tool_calls 索引排序修复（对齐 Android toSortedSet）
- [ ] 2.2 `ChatService`：发送编排（占位/事件落库/终态）、重试、历史裁剪 ≤20 条 ≤48KB、错误码语义
- [ ] 2.3 `DailyReportService`：Mutex 串行、8 条/批、>100 拒绝、48KB 合并阈值、五写点、COMPLETED 防覆盖
- [ ] 2.4 `HitokotoClient` + `Motto`/`CachedMotto` + 按天缓存（UserDefaults suite `motto_cache`）
- [ ] 2.5 ChatDao/DailyReportDao 观察辅助静态查询（sessionsVersion/messagesVersion/dailyReportsSync）
- [ ] 2.6 单测：ChatService 落库序/重试/裁剪/中断；DailyReportService 五写点/分批；Hitokoto URL 构造与解析；Motto 按天缓存

## 3. App 组装与聊天基础设施（design D-3）
- [ ] 3.1 `AgentRuntime`：每次发送按当前配置组装 LlmClient + AgentLoop
- [ ] 3.2 `ChatStore`：会话状态机 Map（Idle/Loading/Generating/ToolCalling/Error）、生成中文本、FailedTurn
- [ ] 3.3 聊天响应式桥接：会话列表 + 当前会话 turns 变更信号重读

## 4. 聊天 UI（spec：会话管理/消息流/工具卡/附件/失败重试）【5a 里程碑：验收点——聊天全流程可手验】
- [ ] 4.1 ChatView 消息流：轮结构（工具时间线 + 气泡）、Markdown 气泡、自动滚动 + 回底按钮、长按菜单
- [ ] 4.2 SessionListView：新建/重命名对话框/删除确认 + 状态图标
- [ ] 4.3 输入区：TextEditor + 发送禁用逻辑 + 10000 字截断 + 附件徽标增删
- [ ] 4.4 ToolCardView：折叠展开/状态图标/耗时/read_notice 深链（预取 notice）
- [ ] 4.5 AttachmentSheet：数据源 → 栏目 → 资讯三层选择
- [ ] 4.6 RetryRow + configRelated「去设置」跳转

## 5. 日报 UI（spec：日报生成与展示）【5b 开始】
- [ ] 5.1 DailyReportView：日期 chips（最新标记）+ Markdown 正文 + 下拉刷新
- [ ] 5.2 四态：生成中/失败（原因+重试）/空态（生成日报入口）/内容
- [ ] 5.3 DailyReportStore：选中日状态机 + 生成并发保护 + 懒加载

## 6. Me tab 与 motto（spec：motto 格言）
- [ ] 6.1 MeView：Hitokoto 头部（署名规则/permalink/点击刷新）+ 三入口（设置/收藏/关于）
- [ ] 6.2 MottoStore：取值优先级（在线缓存/本地默认）+ 懒刷新 + 失败保留缓存
- [ ] 6.3 MottoSettingsView：在线分支（分类下拉 11 类 + max_length 校验 ≤100）与本地分支（text 必填/author 可空）

## 7. 设置中心（spec：LLM 配置/来源编辑器/资讯显示）
- [ ] 7.1 SettingsHomeView：分组导航（通用/LLM/资讯/关于）
- [ ] 7.2 LlmSettingsView：10 预设切换即时持久化、Key 存取（清空即删）、测试连接（30s 超时、≤200 字摘要）、日报开关 + 时间下拉
- [ ] 7.3 SourcesEditorView 三页：列表（订阅态/条数/上次运行摘要）、详情（开关/立即抓取/删除仅侧载/lastError 全文）、脚本编辑（只读内置/校验保存/@id 一致性）
- [ ] 7.4 导入脚本（校验 + 注册）+ 全部抓取（进度/取消，复用 CrawlCoordinator）+ 清空资讯缓存
- [ ] 7.5 NewsDisplaySettingsView：freshDays/crawlDaysGap 正整数校验即时持久化

## 8. 关于与协议（spec：关于与协议）
- [ ] 8.1 AboutView：名称/版本/描述/GitHub 外链/License
- [ ] 8.2 PolicyView：Bundle `PrivacyPolicy.md` Markdown 渲染 + 降级提示

## 9. 验收
- [ ] 9.1 `swift test` 全绿（新增单测后目标 60+）
- [ ] 9.2 模拟器全场景手验：真实 Key 聊天流式 + 工具卡 + 深链、日报手动生成、motto 在线/本地、LLM 测试连接、来源编辑
- [ ] 9.3 `openspec validate` → 汇报 → 归档
