# chat-daily-me Specification（delta）

> 行为契约以 Android 真源为准（`app/src/main/java/org/openjwc/client/`），以下为 iOS 端对齐口径。

## ADDED Requirements

### Requirement: 聊天会话管理
聊天 tab SHALL 展示「新聊天」入口与会话列表（标题空显示「未命名会话」，生成中/错误态有状态图标）；会话支持重命名（标题单行编辑，空串禁用确认）与删除（需确认；删除当前会话回到新聊天态）。首次发送消息时 SHALL 以消息前 20 字（去换行）自动创建会话。

#### Scenario: 新会话自动创建
- **WHEN** 用户在新聊天态发送第一条消息
- **THEN** 自动创建会话并以该消息前 20 字命名，消息入该会话

#### Scenario: 删除当前会话
- **WHEN** 用户删除正在查看的会话并确认
- **THEN** 会话与其消息、工具卡全部删除，界面回到新聊天态

### Requirement: 聊天消息流与 Agent 循环驱动
消息流 SHALL 按「轮」展示：每轮为工具卡时间线（若有）在上 + 消息气泡在下。发送消息 SHALL：插入用户消息 → 插入空 assistant 占位（RUNNING）→ 启动 Agent 循环，逐事件更新 UI 与落库（runId、工具卡逐条、流式正文、终态）。生成中的流式正文 SHALL 只在内存叠加展示，不重复写库；切会话 SHALL 自动重订阅该会话数据。

#### Scenario: 发送并流式生成
- **WHEN** 用户发送消息且 LLM 配置有效
- **THEN** 用户气泡立即出现，助手侧显示生成中指示，正文随 AnswerDelta 流式更新，完成后正文已持久化

#### Scenario: 切换会话
- **WHEN** 用户从会话 A 切换到会话 B
- **THEN** 消息流切换为 B 的历史（含工具卡），生成中状态互不干扰

#### Scenario: 历史还原
- **WHEN** 用户杀掉 App 重新进入某会话
- **THEN** 消息与工具卡从数据库完整还原（含失败/中断的消息终态）

### Requirement: 工具卡片
每个工具调用 SHALL 生成一张卡片：标题（工具展示名）、summary（默认折叠为首行，可展开）、状态图标（运行中/完成/失败）、耗时；仅 `read_notice` 工具卡在带 targetId 时 SHALL 可点击跳转该资讯详情，其余工具卡点击仅切换折叠。

#### Scenario: read_notice 深链
- **WHEN** Agent 调用 read_notice 并返回 targetId
- **THEN** 对应工具卡出现跳转图标，点击进入该资讯详情页

#### Scenario: 工具卡还原
- **WHEN** 历史会话中某条消息含 3 个工具调用
- **THEN** 渲染 3 张卡片，状态与耗时与落库一致

### Requirement: 引用资讯附件
用户可在聊天输入区通过底部 sheet 选择资讯作为附件引用（按数据源 → 栏目 → 资讯三层选择）；附件 SHALL 以标题徽标展示在用户气泡上方，随消息发送进入 Agent 上下文（引用资讯块）；可逐个移除。

#### Scenario: 添加引用附件
- **WHEN** 用户在附件 sheet 选中一条资讯
- **THEN** 输入区上方出现该资讯标题徽标，发送后徽标随用户气泡展示

#### Scenario: 发送时清空
- **WHEN** 用户发送带附件的消息
- **THEN** 输入框与附件列表清空

### Requirement: 失败与重试
Agent 循环失败（LLM 错误/中断/取消）SHALL：该轮 assistant 占位落库为 FAILED + 错误码，UI 显示错误态与「重试」行（固定位于最后一条用户消息之后）；重试 SHALL 复用原文本与附件（不重复插入用户消息）。错误码属配置相关（401/403/404/配置缺失类）时 SHALL 提供跳转 LLM 设置的入口。流未到终态的发送 SHALL 视为中断落库（agent_interrupted）。

#### Scenario: 失败后重试
- **WHEN** 生成失败（如网络错误）后用户点重试
- **THEN** 复用原消息与附件重新发起，不产生重复的用户消息行

#### Scenario: 配置错误跳设置
- **WHEN** 失败码为配置相关（如未配置 Key）
- **THEN** 错误提示附带「去设置」入口，点击进入 LLM 设置页

### Requirement: 日报生成与展示
日报 tab SHALL 展示已完成日报的日期 chips（最新一份带「最新」标记）与选中日的 Markdown 正文；无任何完成稿时显示空态与「生成日报」入口。手动生成 SHALL：目标日默认昨天；当日资讯 > 100 条报错；按 8 条一批逐批 LLM 摘要、多批时合并（拼接 > 48KB 跳过合并轮）；状态机 running/completed/failed 持久化，已完成的日报不可被覆盖；生成中重复触发 SHALL 被忽略。失败时展示错误原因（截 300 字）与重试入口。

#### Scenario: 首次生成日报
- **WHEN** 用户在有资讯语料的日子点「生成日报」
- **THEN** 显示生成中状态，完成后正文 Markdown 展示并出现在日期 chips

#### Scenario: 已完成不可覆盖
- **WHEN** 用户对已完成的日子再次触发生成
- **THEN** 直接返回已有完成稿，不重新生成

#### Scenario: 当日无资讯
- **WHEN** 目标日没有任何已收录资讯
- **THEN** 直接生成完成态的「当日没有已收录的资讯。」文案

### Requirement: motto 格言
Me tab 头部 SHALL 展示格言：`mottoOnline` 开启时展示 hitokoto 在线一言（含作者/来源与永久链接），关闭时展示本地格言（默认「笃学尚行」；作者空或「佚名」不展示署名）。在线模式 SHALL 按天缓存（当日已有缓存不重复请求），点击正文可手动刷新（仅在线模式）；请求失败保留缓存并提示。

#### Scenario: 在线一言按天缓存
- **WHEN** 当日已成功获取过一言且用户再次进入 Me tab
- **THEN** 直接展示缓存，不发起网络请求

#### Scenario: 本地模式
- **WHEN** 用户关闭在线开关并保存自定义文本
- **THEN** Me 头部立即展示自定义文本与作者

### Requirement: LLM 配置
LLM 设置页 SHALL 提供：供应商选择（10 预设：openai/deepseek/moonshot/zhipu/qwen/openrouter/siliconflow/groq/ollama/custom，选择即回填 baseUrl/model 并立即持久化）、baseUrl、model、API Key（存 Keychain，按 providerId 隔离；清空即删除）；「测试连接」SHALL 用输入框当前值（不要求先保存）发起一次流式对话验证，30 秒超时，结果与错误展示在页内。日报开关与时间（00:00/06:00/08:00/12:00/18:00/22:00）SHALL 在本页配置（调度本身属阶段 7）。

#### Scenario: 切换供应商预设
- **WHEN** 用户选择 deepseek 预设
- **THEN** baseUrl/model 回填预设值，Key 输入框切换为该 providerId 的已存 Key，配置立即持久化

#### Scenario: 测试连接
- **WHEN** 用户填好 Key 后点测试连接（未先保存）
- **THEN** 以当前输入值发起流式请求，成功显示回复摘要（≤200 字），失败显示错误原因

### Requirement: 来源编辑器
来源编辑器 SHALL 展示全部数据源（订阅态着色、id · 本地条数 · 订阅态 · 上次运行摘要/错误首行）与抓取回溯天数（crawlDaysGap）编辑；单源操作：订阅开关、立即抓取、脚本查看（内置只读）或编辑（侧载，保存前静态校验且 @id 必须一致）、删除（仅侧载可删）；全局操作：导入脚本（校验通过后注册，默认订阅）、全部抓取（复用抓取编排，进度/日志/取消）、清空资讯缓存（需确认）。

#### Scenario: 编辑侧载脚本
- **WHEN** 用户修改侧载脚本并保存
- **THEN** 先静态校验（语法 + fetchNotices 定义）与 @id 一致性，通过后更新 manifest 字段（含 scheduleMinutes）并落库

#### Scenario: 内置源不可删
- **WHEN** 用户尝试删除内置源
- **THEN** 无删除入口（或操作被拒绝）

### Requirement: 资讯显示设置
设置中心 SHALL 提供 freshDays（fresh 高亮窗口）与 crawlDaysGap（抓取回溯天数）的正整数编辑，校验通过且值变更时持久化，下一屏即时生效。

#### Scenario: 修改 freshDays
- **WHEN** 用户把 freshDays 从 21 改为 7
- **THEN** 保存后资讯列表的高亮窗口按 7 天生效

### Requirement: 关于与协议
Me tab SHALL 提供「关于」页（应用名/版本号/项目描述/GitHub 外链/License）与「用户协议」页（渲染内置协议文档全文，读取失败降级为提示文案）。收藏入口 SHALL 从 Me tab 进入收藏页（复用阶段 4 收藏页）。

#### Scenario: 打开协议页
- **WHEN** 用户进入用户协议页
- **THEN** 完整渲染内置协议 Markdown 文档

### Requirement: 响应式数据桥接（聊天/日报）
会话列表、当前会话消息流、日报完成稿列表 SHALL 由数据库变更信号驱动 UI（观察表变更触发命令式重读）；App 重启后工具轨迹与消息 SHALL 从 DB 还原；观察 SHALL 在视图生命周期内启停，不泄漏。

#### Scenario: 新会话即时出现
- **WHEN** 发送首条消息创建了新会话
- **THEN** 会话列表（历史抽屉）无需手动刷新即出现该会话
