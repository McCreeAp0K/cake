# 本地 AI Agent 监控 App —— 技术实现报告

> 产品代号：**Cake**（暂定）
> 形态：常驻 macOS 刘海区域（模拟"灵动岛"）的轻量监控中枢
> 架构定位：**纯客户端 macOS 原生 App，无后端、纯本地、只读、零侵入**
> 目标平台：macOS 14 Sonoma+（实测环境 macOS 26.5 Tahoe / Apple M3 Pro，带刘海屏）
> 文档版本：v2.0 ｜ 日期：2026-06-18 ｜ 较 v1.0 变更见 §0

---

## 0. v2.0 变更摘要

| 编号 | 变更 | 原因 |
|---|---|---|
| C1 | 新增 **§3 架构定位：纯客户端、无后端**，论证为何不需要服务器 | 明确产品形态 |
| C2 | **修正 OTLP 采集方式**：从"自起 OTLP 接收器监听端口"改为"读取 OTel collector 落地的 logs 文件" | 本机已有 collector 占用 OTLP 端口，自起会冲突；纯客户端不应抢占系统端口 |
| C3 | **§5 功能模块**由一张清单表扩展为 10 个模块的详细规格（输入/输出/UI/算法/边界） | 应需求把模块和功能讲细 |
| C4 | 新增 **§6.x 组件级架构**（数据流分层、线程模型、持久化 schema） | 补充实现细节 |
| C5 | 澄清**平台为 macOS 而非 iOS**：本产品依赖本机文件/进程/刘海窗口，iOS 沙盒不具备这些能力 | 术语校正 |

---

## 1. 背景与目标

随着开发者本机同时运行多个 AI 编码 Agent（Claude Code、Kiro CLI、Amazon Q CLI 等），出现了几个痛点：

1. **后台任务"黑盒"** —— 把一个长任务丢给 Agent 后切走，不知道它是还在跑、卡住了、还是已经完成（甚至在等你输入）。
2. **Token / 成本不可见** —— 各工具分散计费，缺乏一个统一的"今天烧了多少 token / 多少钱"的视图。
3. **模型选择不透明** —— 当前会话到底用的是 Opus 4.8 还是 Sonnet 4.6，多个窗口里各用了什么模型，难以一眼看清。
4. **缺少及时提醒** —— 任务完成或需要人工介入时没有醒目通知。

**Cake** 的目标：把分散在各 CLI 本地数据中的运行状态、token 用量、模型选择、任务进度，聚合到一个常驻刘海区域的小部件里，做到**一瞥即知（glanceable）、点击即展开（expandable）、完成即提醒（notify）**。

### 1.1 核心设计原则

- **纯本地、只读、零侵入**：只读取各工具已经写在本地的数据文件 / 遥测落地文件，不修改任何 Agent 的行为，不上传任何数据到云端。
- **被动观测优先**：优先消费工具"自己已经产生"的数据（JSONL 会话日志、OTel 落地日志、SQLite），而非注入或 hook。
- **可扩展适配器架构**：每个 Agent 工具是一个独立的 `AgentProvider` 插件，新增工具不影响核心。
- **降级而非崩溃**：任一数据源解析失败时，退回到更弱但更稳的信号（如进程探测），保证至少能显示"在跑/没跑"。

---

## 2. 竞品调研（市面已有产品）

设计前调研了三类相关产品，Cake 是这三类的交集。

### 2.1 刘海 / 灵动岛类 UI 框架

| 产品 | 形态 | 技术栈 | 可借鉴点 |
|---|---|---|---|
| **boring.notch**（开源，GPL-3.0） | 把刘海变成媒体控制+文件 shelf+HUD | Swift / SwiftUI，含 `XPCHelper` 独立进程 | 刘海悬停展开交互、围绕刘海的窗口布局、`mediaremote-adapter` 模式 |
| **NotchNook**（商业） | 刘海多功能托盘（剪贴板、shelf、通知镜像） | AppKit + 自绘 | 商业化交互范式、多模块切换 |
| **DynamicLake / NotchDrop** | 灵动岛动画 + 拖拽中转站 | SwiftUI | 展开/收起动画、拖拽手势 |
| **Island（iPhone 灵动岛原型）** | Apple 系统级 | 私有 API（不可用于第三方 Mac） | 仅交互语言参考 |

> **关键结论**：macOS **没有公开的"灵动岛 API"**。所有第三方刘海应用都是用一个**无边框、置顶、覆盖刘海区域的 `NSWindow`** 自己绘制实现的（详见 §6.2）。这也是本产品必须是 **macOS 原生** 而非 iOS 的根本原因之一。

### 2.2 AI Token / 成本监控类

| 产品 | 能力 | 数据来源 | 可借鉴点 |
|---|---|---|---|
| **ccusage**（开源，MIT） | 解析多家编码 CLI 的本地用量，出日/周/月/会话报表，区分 cache token，按 LiteLLM 定价算成本 | 各 CLI 本地 JSONL | **多工具统一聚合**、cache token 分类、离线定价、5 小时计费窗口 |
| **Claude-Code-Usage-Monitor** | 实时盯 token 燃烧速率、预测额度耗尽时间 | `~/.claude` JSONL | 燃烧速率 / 预测耗尽 |
| **OpenCost / LiteLLM dashboard** | 模型成本聚合 | API 网关 | 定价表抽象 |

> ccusage 本身就是一个**纯命令行、读本地文件、零后端**的工具——这佐证了"聚合本地 AI 用量"这件事根本不需要服务器（见 §3）。

### 2.3 进程 / 任务状态监控类

| 产品 | 能力 | 可借鉴点 |
|---|---|---|
| **macOS 活动监视器 / htop** | 进程级 CPU/内存 | 进程探测兜底 |
| **CCStatusline / 各类 statusline 插件** | 在终端状态栏显示当前模型/用量 | 状态字段定义 |

**Cake 的差异化定位**：把"ccusage 的统一用量聚合" + "进程/会话活跃度探测" + "boring.notch 的刘海 UI" 三者合一，且**面向多 Agent 并发的后台任务监控**这个尚无成熟产品覆盖的细分场景。

---

## 3. 架构定位：纯客户端、无后端

### 3.1 结论

Cake 是一个**单进程的 macOS 原生 App**，**不需要任何后端服务器**。理由：**所有数据本来就在本机**，App 的全部职责是"就地读取 → 内存聚合 → 本地展示/存档"。

### 3.2 为什么不需要后端

| 所需数据 | 已存在的本地位置 | 是否需要网络 |
|---|---|---|
| Claude Code token / 模型 | `~/.claude/projects/**/*.jsonl`、OTel 落地日志（可选） | ❌ 纯本地 |
| Kiro 会话 / 状态 | `~/.kiro/sessions/cli/`、`data.sqlite3` | ❌ 纯本地 |
| 进程活跃度 | 内核进程表（`proc_listpids` / `pgrep`） | ❌ 纯本地 |
| 历史聚合 / 报表 | App 自带的本地 SQLite | ❌ 纯本地 |
| 模型定价表 | App 内置静态文件（可选离线更新） | ❌ 纯本地（更新为可选） |

> 关键澄清：若本机有 OTel collector，它通常**只绑定本地回环**，是本机进程间通信，不是远程服务。Cake **不连接也不抢占**它，而是读取它落地的日志文件（见 C2 / §7.4）。

### 3.3 纯客户端的收益

- **隐私**：零网络出站，代码/prompt 不出本机——这是最大卖点。
- **零配置**：装上即用，无需登录、无需配服务器地址。
- **离线可用**：断网照常工作。
- **低运维**：没有服务器要维护、没有账号体系、没有数据合规负担。

### 3.4 边界：什么时候才需要后端（均不在当前范围）

| 未来功能 | 才需要的后端 | 处理策略 |
|---|---|---|
| 跨设备汇总（多台 Mac） | 同步存储 | 后续可选模块，核心 App 不动 |
| 团队/组织用量看板 | 聚合服务 | 独立产品线 |
| 定价表在线更新 | 一个静态 JSON/CDN | 算不上真后端；可内置 + 可选拉取 |

---

## 4. 本机数据源勘探结果（实测）

以下是在目标机器上实际勘探到的数据源，是适配器设计的事实依据。

### 4.1 Claude Code（已安装，正在运行）

由 Claude Code 启动。

**数据源 A —— 会话 JSONL（主用量来源，权威）**
- 路径：`~/.claude/projects/<工程路径转义>/<sessionId>.jsonl`
  - 例：`~/.claude/projects/-Users-you-project/093fc98b-…f80601fa6d83.jsonl`
- 每个 `assistant` 类型的行内含 `message.usage`，字段实测如下：
  ```json
  {
    "type": "assistant",
    "message": {
      "model": "claude-opus-4-8",
      "usage": {
        "input_tokens": 131,
        "output_tokens": 288,
        "cache_creation_input_tokens": 951,
        "cache_read_input_tokens": 47425,
        "service_tier": "standard",
        "cache_creation": { "ephemeral_5m_input_tokens": 951, "ephemeral_1h_input_tokens": 0 }
      }
    }
  }
  ```
- **可直接得到**：每次回合的 input/output/cache 四类 token、**当前模型**、service tier。

**数据源 B —— OTel 落地日志（实时来源，可选）**
- 若 Claude Code 开启了遥测，并由 OTel collector 配置 `file/logs` exporter 把日志按 JSON 落到文件，则可读取。
- 事件 `claude_code.api_request`（含 `model`、`session.id`、各类 token、`cost_usd` 等维度）。
- **采集方式**：Cake **不绑定任何端口**，而是 **只读 tail 该落地日志文件**，得到准实时的 token 增量与成本；路径由环境变量 `CAKE_OTEL_LOG` 指定，未配置则自动退回 JSONL。

**数据源 C —— 提示历史**
- `~/.claude/history.jsonl`：字段 `display / pastedContents / timestamp / project / sessionId`。

**数据源 D —— 进程**
- `ps` 可见 `…/claude` 进程，命令行参数里直接带有模型配置（`ANTHROPIC_CUSTOM_MODEL_OPTION=…opus-4-8…` 等），可作为模型/活跃度的兜底信号。

### 4.2 Kiro CLI（已安装）

- **CLI 会话**：`~/.kiro/sessions/cli/<id>.{json,jsonl,history,lock}`
  - `<id>.json` 顶层键：`session_id / cwd / created_at / updated_at / title / session_created_reason / session_state`
  - `<id>.jsonl` 每行结构：`{version, kind, data}`（事件流）
  - **`<id>.lock` 文件 = 会话正在运行的强信号**（进程持有锁）
- **SQLite**：`~/Library/Application Support/kiro-cli/data.sqlite3`
  - 表：`conversations_v2 / conversations / history / state / auth_kv / migrations`
- **日志**：`~/.kiro/logs/<时间戳>/{kiro.log, mcp.log, powers.log}`
- **IDE 端（Electron）**：`~/Library/Application Support/Kiro/`（VS Code 衍生，`state.vscdb` 内 `ItemTable`），进程名 `Kiro Helper (…)`。

> Kiro 的 token 字段需进一步从 `conversations_v2` 表或 `.jsonl` 的 `data` 体内解析（本次勘探未在样本行直接命中 `usage`，列为适配器待实现细节，见 §11 风险）。

### 4.3 Amazon Q CLI（本机未安装，`q not found`）

通用约定（按官方目录约定设计，安装后验证）：
- 配置 / 会话：`~/.aws/amazonq/`
- 进程名：`q` / `q chat` / `amazon-q`
- 适配器先以**进程探测 + 目录监听**兜底，安装后再补精确字段。

### 4.4 环境约束

- macOS **26.5（Tahoe）**，**Apple M3 Pro**，**Built-in Liquid Retina XDR（带刘海）**，分辨率 3456×2234。
- 无公开灵动岛 API → 自绘刘海窗口（§6.2）。

---

## 5. 功能模块详述

全产品分为 **10 个功能模块（M1–M10）**。本节逐个给出：定位、输入数据、核心逻辑、UI 呈现、边界与降级。

> 优先级标记：**P0**=MVP 必做；**P1**=重要；**P2**=增强。

---

### M1 · 运行状态监控 〔P0〕

**定位**：回答"我的每个 AI Agent 现在到底在干嘛？"——这是整个产品的地基。

**输入数据**
- Claude：OTel 落地日志的 token 心跳 + JSONL 末行时间 + 进程存活。
- Kiro：`.lock` 文件存在性 + `.jsonl` 末行时间 + `session_state` 字段。
- Amazon Q：进程存活 + 目录 mtime。

**核心逻辑 —— 会话状态机**（详见 §5 状态机定义在 M2）
每个会话维护一个 `AgentState`：

| 状态 | 含义 | 主要判据 |
|---|---|---|
| `running` | 正在生成 | token 持续增长 / OTel 心跳活跃 / `.lock` 存在 |
| `waiting-input` | 跑完一轮，等你输入 | 进程存活 + 末条为 assistant + token 停滞 > N 秒 |
| `done` | 任务结束 | 进程退出 / 锁释放 |
| `idle` | 长时间无活动 | 超过空闲阈值无任何信号 |
| `error` | 出错 | 日志/退出码含错误 |

**UI 呈现**
- 收起态：刘海左侧一个圆点徽标 `●N`，N=当前活跃会话数；颜色随"最关键状态"变化（有 error 红 > 有 waiting 黄 > 全 running 蓝 > 全 done/idle 灰）。
- 展开态：每个会话一行，左侧状态图标（⟳ 旋转 / ⏸ / ✓ / ⏹ / ⚠），右侧时长。

**边界与降级**
- 任一精细信号缺失时，退回"进程在不在"这个最弱但最可靠的二元信号，至少显示 running/done。

---

### M2 · 后台任务完成检测与提醒 〔P0〕

**定位**：产品的"杀手级"功能——你把任务丢给 Agent 切去做别的，**它干完了主动拍你肩膀**。

**核心逻辑 —— 完整状态机**
```
                  有新 assistant 输出 / token 增长
        idle ───────────────────────────────► running
          ▲                                      │
          │ 超时无活动                            │ token 停滞 N 秒
          │ (>空闲阈值)                           │ 且进程仍存活
          │                                      ▼
        done ◄──────── 进程退出 / 锁释放 ──── waiting-input
                                                 │
                            日志/退出码含 error   ▼
                                              error
```

**判定信号来源（多信号融合）**
- **进程存活**：`proc_listpids` / `pgrep -f claude|kiro|q`。
- **锁文件**：Kiro `~/.kiro/sessions/cli/<id>.lock` 存在 = 活跃。
- **文件 mtime / 新增行**：JSONL 末行时间 + FSEvents 监听。
- **OTel 心跳**：Claude `claude_code.token.usage` 持续上报 = 活跃。
- **"等待输入"启发式**：进程存活 + 末条为 assistant + token 停滞超阈值（阈值可调，默认 8–15s）。

**触发动作（分级）**
| 事件 | 动作 |
|---|---|
| `running → done` | 系统通知"✓ Claude 任务完成（耗时 2m14s）" + 刘海绿色脉冲动画 + 可选提示音 |
| `running → waiting-input` | 刘海黄色 ⏸ + 通知"Claude 在等你输入" |
| `→ error` | 红色闪烁 + 通知含错误摘要 |

**边界与降级**
- 误判防护：用"token 停滞时长 + 进程状态"双信号，避免把"模型思考慢"当成"等待输入"；阈值可在设置里调。
- 通知去抖：同一会话状态在短时间内反复抖动时合并通知。

---

### M3 · Token 用量统计 〔P0〕

**定位**：统一回答"今天/这个会话/这个工具，烧了多少 token、多少钱"。

**输入数据**
- Claude：JSONL `message.usage` 的四类 token（权威）+ OTel 增量（实时）。
- Kiro/Q：从各自数据源解析（见风险）。

**核心逻辑**
- 四类 token 分别累加：`input` / `output` / `cache_read` / `cache_create`。
- **去重**：OTel（实时增量）与 JSONL（权威终值）可能重复计同一会话；以 `sessionId + 回合序号` 为键去重，JSONL 落地后以其为准、覆盖 OTel 的估算。
- **燃烧速率**：滑动窗口（如最近 5 分钟）算 tokens/min。
- 多维聚合：按 会话 / 工具 / 模型 / 时间桶（小时、天）。

**UI 呈现**
- 收起态：刘海右侧 `▲ 1.2M tok · $4.10`（今日累计）。
- 展开态 Tokens Tab：今日总量、四类 token 占比条、按工具/模型分组的小计、燃烧速率折线。

**边界**
- cache_read 量级大（实测单回合可达 4.7 万），必须单列，否则会严重高估成本。

---

### M4 · 模型可视化 〔P1〕

**定位**："我现在各窗口用的什么模型？今天哪个模型用得最多？"

**输入数据**：各会话快照的 `model` 字段（Claude 实测 `claude-opus-4-8`）。

**核心逻辑**
- 当前会话 → 模型的实时映射。
- 今日各模型 token / 成本占比（饼图数据）。
- "最常用模型"排行（按 token 或按调用次数）。
- 模型名归一化：把 `global.anthropic.claude-opus-4-8[1m]` 这类长 ID 映射成展示名 `Opus 4.8`。

**UI 呈现**
- 每个会话行尾显示模型 chip（`Opus 4.8` / `Sonnet 4.6`）。
- 展开面板一个"今日模型分布"环形图。

---

### M5 · 历史与报表 〔P1〕

**定位**：对标 ccusage 的日/周/月报表，但带 GUI。

**输入数据**：本地 SQLite 中的聚合事实表（见 §6.4）。

**核心逻辑**
- 时间维度汇总：日 / 周 / 月 / 自定义区间。
- 维度切片：工具、模型、工程目录（cwd）。
- 导出：CSV / JSON（字段对齐 ccusage `--json`，便于复用生态）。

**UI 呈现**
- 展开面板 History Tab：日历热力图（每日用量）、Top 工程、Top 模型、趋势折线。

---

### M6 · 多 Agent 聚合视图 〔P0〕

**定位**：把 Claude / Kiro / Q 的并发会话**汇总到一屏**，这是"监控中枢"的核心价值。

**核心逻辑**
- 把各 `AgentProvider` 推送的 `SessionSnapshot` 流合并、按状态/活跃度排序（running 置顶、error 更靠前）。
- 全局汇总卡：活跃会话总数、今日总 token、今日总成本。
- 跨工具去同名工程聚合（同一 cwd 下多个工具的活动归并显示）。

**UI 呈现**：展开面板 Live Tab 的会话列表 + 顶部全局汇总条。

---

### M7 · 通知与提醒 〔P0〕

**定位**：把 M2 的事件，以及预算/错误事件，统一成分级通知系统。

**核心逻辑 —— 通知规则引擎**
| 级别 | 事件 | 默认渠道 |
|---|---|---|
| 信息 | 任务完成 | 刘海脉冲 + 系统通知 |
| 提醒 | 等待输入 | 刘海高亮 + 系统通知 |
| 警告 | 预算接近上限（M10） | 系统通知 + 声音 |
| 错误 | 会话 error | 刘海红闪 + 系统通知 + 声音 |

- 使用 `UNUserNotificationCenter` 发系统通知。
- 用户可按"工具 × 级别"开关、设勿扰时段、关声音。

---

### M8 · 快捷操作 〔P2〕

**定位**：从监控直接跳到行动。

**功能**
- 点击会话 → **聚焦到对应终端窗口**（通过窗口标题/工作目录匹配 + AppleScript/Accessibility 激活）。
- "在 Finder 打开工程目录"、"在编辑器打开"。
- 复制 `sessionId` / 复制本会话用量摘要。

**边界**：跳转终端依赖辅助功能权限；拿不到时降级为"打开工程目录"。

---

### M9 · 偏好设置 〔P1〕

**定位**：所有可配置项的归集。

**功能分组**
- **数据源**：勾选监控哪些工具；自定义数据目录路径（应对非默认安装）。
- **外观**：刘海模式 / 无刘海"胶囊"模式；收起态显示什么（会话数 / token / 成本）。
- **通知**：M7 规则、勿扰时段、声音。
- **计费**：定价表选择 / 自定义覆盖（§7.5）；货币。
- **隐私**：是否抓取会话标题、是否记录工程路径（默认仅聚合指标）。
- **行为**：开机自启（`SMAppService`）、空闲/等待阈值、轮询间隔。

---

### M10 · 额度与预算 〔P2〕

**定位**："别让我月底才发现烧超了。"

**核心逻辑**
- 用户设日/月预算阈值（按成本或 token）。
- 实时对比累计值，跨阈值（如 80% / 100%）触发 M7 警告。
- **预测耗尽时间**：用当日燃烧速率线性外推，估"按这个速度今天还能用 X 小时 / 本月 Y 号到顶"。

**UI**：展开面板顶部一条预算进度条（绿→黄→红）。

---

### 5.11 模块依赖与优先级总览

```
数据采集层 (Provider) ──► M1 状态 ──► M2 完成检测 ──► M7 通知
        │                  │
        └──► M3 token ──► M4 模型      M6 聚合视图 (汇总 M1/M3/M4)
                 │
                 ├──► M5 报表
                 └──► M10 预算 ──► M7 通知
   M8 快捷操作 / M9 设置 横切所有模块
```
- **MVP（P0）**：M1 + M2 + M3 + M6 + M7（只接 Claude Code）。
- **P1**：M4 + M5 + M9。
- **P2**：M8 + M10 + 更多工具。

---

## 6. 技术架构

### 6.1 信息架构（三层展开 UI）

模拟灵动岛的"收起 / 悬停 / 展开"三态：

```
┌─ 收起态 (Idle / Compact) ──────────────────────────────┐
│  [刘海左侧] ●3 agents     [刘海右侧] ▲ 1.2M tok  $4.10  │   ← 一瞥即知
└────────────────────────────────────────────────────────┘
        ↓ 悬停 (Hover) — 横向轻展开
┌─ 悬停态 (Peek) ─────────────────────────────────────────┐
│  ⟳ Claude · Opus4.8 · running 2m   ✓ Kiro · done        │
│  ⏸ Q · waiting input                                    │
└─────────────────────────────────────────────────────────┘
        ↓ 点击 (Click) — 向下展开面板
┌─ 展开态 (Expanded Panel) ───────────────────────────────┐
│  Tab: [Live] [Tokens] [History]                         │
│  ──────────────────────────────────────────────────     │
│  ⟳ Claude Code  Opus 4.8   running · 2m14s              │
│     session 093f… · /Users/you/Amazon              │
│     ▓▓▓▓▓▓░░ 48k ctx · ↑131 ↓288 · cache 47k            │
│  ✓ Kiro CLI     done · 3m ago   "重构登录模块"           │
│  ⏸ Amazon Q     waiting for input                       │
│  ──────────────────────────────────────────────────     │
│  Today: 1.24M tokens · $4.10   [按模型/工具切换]         │
└─────────────────────────────────────────────────────────┘
```

### 6.2 总体架构（纯客户端单进程）

```
┌─────────────────────────────────────────────────────────────┐
│                Cake.app (macOS, 单进程, LSUIElement)    │
│                                                              │
│  ┌────────────┐   ┌─────────────────┐   ┌────────────────┐  │
│  │ Notch UI   │◄──│  ViewModel      │◄──│ AggregationCore │  │
│  │ (NSWindow  │   │ (@Observable)   │   │ (状态机/聚合)    │  │
│  │  overlay)  │   └─────────────────┘   └───────▲────────┘  │
│  └────────────┘                                 │           │
│  ┌──────────────────────────────────────────────┴────────┐  │
│  │              Provider 适配器层 (协议)                    │  │
│  │  ClaudeCodeProvider │ KiroProvider │ AmazonQProvider     │  │
│  └───────▲─────────────────▲───────────────▲──────────────┘  │
│          │                 │               │                 │
│  ┌───────┴──────┐  ┌───────┴──────┐ ┌──────┴───────┐         │
│  │ OTel 日志    │  │ FSEvents 文件 │ │ Process 探测  │         │
│  │ tail (只读)  │  │ 监听 + JSONL  │ │ (proc_pids)  │         │
│  │              │  │ tail / SQLite│ │              │         │
│  └──────────────┘  └──────────────┘ └──────────────┘         │
│                                                              │
│  ┌──────────────┐  本地持久化 (历史聚合): SQLite/GRDB         │
│  └──────────────┘   ← 全部读本机文件，零网络出站              │
└─────────────────────────────────────────────────────────────┘
```

### 6.3 刘海窗口实现（UI 核心）

> macOS 无灵动岛 API，需自绘。借鉴 boring.notch 的做法。

- **窗口**：一个 `NSWindow` 子类，设置：
  - `level = .statusBar`（或 `.mainMenu + 1`，确保盖在菜单栏/刘海上方）
  - `styleMask = .borderless`、`isOpaque = false`、`backgroundColor = .clear`
  - `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`（跟随所有桌面、全屏下仍可见）
  - `ignoresMouseEvents` 动态切换：收起态对非刘海区域放行点击，悬停区域接收事件。
- **定位**：用 `NSScreen.main.safeAreaInsets` / `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`（macOS 12+）拿到刘海两侧区域；对**无刘海的外接屏**降级为顶部居中"胶囊"悬浮条。
- **内容**：`NSHostingView` 承载 SwiftUI 视图；三态用 `matchedGeometryEffect` + `withAnimation(.spring)` 做展开/收起动画。
- **悬停检测**：`NSTrackingArea` 覆盖刘海下方热区，鼠标进入 → Peek，点击 → Expanded。
- **多屏**：监听 `NSApplication.didChangeScreenParametersNotification`，重新计算刘海几何。

### 6.4 数据流与线程模型

```
[文件/进程/日志]
   │ (后台串行队列, 每个 Provider 一条)
   ▼
Provider 解析 → SessionSnapshot (值类型)
   │ (AsyncStream)
   ▼
AggregationCore (actor, 线程安全聚合 + 状态机)
   │ (主线程 hop)
   ▼
ViewModel (@MainActor @Observable)
   ▼
SwiftUI 刘海视图
```
- 每个 Provider 在**独立后台队列**做 IO 与解析，避免阻塞 UI。
- `AggregationCore` 用 Swift `actor` 保证并发安全。
- 仅在最后一跳切回 `@MainActor` 更新 UI。
- 采集节流：FSEvents 合并抖动，OTel/SQLite 轮询 5–10s，进程探测 2–5s。

### 6.5 Provider 适配器协议

```swift
protocol AgentProvider {
    var id: AgentKind { get }            // .claudeCode / .kiroCli / .amazonQ
    var isInstalled: Bool { get }        // 探测可执行/目录是否存在
    func start() async                   // 启动 watcher（文件/进程/日志）
    func stop()
    var sessions: AsyncStream<SessionSnapshot> { get }  // 增量推送会话快照
}

struct SessionSnapshot {
    let provider: AgentKind
    let sessionId: String
    let title: String?
    let cwd: String?
    let model: String?                   // e.g. "claude-opus-4-8"
    let state: AgentState                // running/waiting/done/idle/error
    let lastActivity: Date
    let tokens: TokenCounters            // input/output/cacheRead/cacheCreate
    let estimatedCostUSD: Double?
}
```

### 6.6 本地持久化 Schema（草案）

```sql
-- 会话维度
CREATE TABLE session (
  session_id TEXT PRIMARY KEY,
  provider   TEXT,          -- claudeCode/kiroCli/amazonQ
  title      TEXT,
  cwd        TEXT,
  model      TEXT,
  started_at INTEGER,
  ended_at   INTEGER,
  last_state TEXT
);

-- 用量事实表（按回合/时间桶累加）
CREATE TABLE usage_event (
  id           INTEGER PRIMARY KEY,
  session_id   TEXT,
  ts           INTEGER,    -- 时间戳
  model        TEXT,
  input        INTEGER,
  output       INTEGER,
  cache_read   INTEGER,
  cache_create INTEGER,
  cost_usd     REAL,
  UNIQUE(session_id, ts, model)   -- 去重键，防 OTel/JSONL 重复计
);
```

### 6.7 三种采集方式（按优先级与可靠性）

| 方式 | 适用工具 | 实时性 | 实现 |
|---|---|---|---|
| **OTel 日志 tail**（修正后） | Claude Code | 准实时 | **只读 tail** OTel collector 落地的 logs 文件，解析 api_request 事件；**不绑定端口** |
| **FSEvents + JSONL tail** | Claude Code、Kiro CLI | 准实时（秒级） | 监听 `~/.claude/projects`、`~/.kiro/sessions/cli`，增量读末行解析 `usage` |
| **SQLite 轮询** | Kiro CLI（`data.sqlite3`） | 轮询（5–10s） | 只读打开（`mode=ro`，`immutable=1` 防锁），查 `conversations_v2`/`history` |
| **进程探测**（兜底） | 全部，尤其 Amazon Q | 轮询（2–5s） | `proc_listpids` / `pgrep -f` 判活跃、读命令行参数取模型 |

> **隔离原则**：所有文件 / SQLite 一律**只读**打开，绝不写入 Agent 的数据目录，符合"零侵入"与生产安全要求。

### 6.8 技术栈选型

| 层 | 选型 | 理由 |
|---|---|---|
| UI | **SwiftUI + AppKit（NSWindow）** | 刘海覆盖必须 AppKit 起窗，内容用 SwiftUI 高效开发；与 boring.notch 一致 |
| 语言 | **Swift 5.9+ / Swift Concurrency（actor/async）** | 原生、低占用、可访问 `NSScreen.safeAreaInsets` 等 |
| 文件监听 | **FSEvents / DispatchSource** | 系统级、低开销 |
| 本地存储 | **GRDB（SQLite）** | 历史聚合、报表查询；同时用于只读访问 Kiro 的 sqlite |
| 进程探测 | **libproc `proc_listpids`** | 比 shell 出 `pgrep` 更快更稳，无子进程开销 |
| 通知 | **UserNotifications (`UNUserNotificationCenter`)** | 系统级通知 |
| 自启 | **`SMAppService`** | 现代登录项 API |
| 打包分发 | Xcode + Sparkle（自更新）/ 直接 notarized DMG | 对标 boring.notch |
| 后台常驻 | `LSUIElement=true`（Agent 型 App，无 Dock 图标） | 常驻不打扰 |

---

## 7. 关键交互流程（任务完成检测端到端）

```
Claude Code 跑长任务
   │  (collector 持续把事件落到日志 / JSONL 持续追加 assistant 行)
   ▼
Watcher tail 日志检测到 token 持续增长 ──► 状态机置 running，刘海左侧 ●计数+1，图标 ⟳ 旋转
   │
   │  token 停止增长 N 秒 + 进程仍在
   ▼
判定 waiting-input 或 done：
   ├─ 进程退出 / 锁释放 ──► done ──► 系统通知"✓ Claude 任务完成（耗时 2m14s）" + 刘海绿色脉冲
   └─ 进程存活、末条 assistant ──► waiting-input ──► 刘海黄色 ⏸ + 通知"Claude 等待你的输入"
```

---

## 8. 权限与沙盒

| 能力 | 所需权限 | 说明 |
|---|---|---|
| 读 `~/.claude`、`~/.kiro` | 用户主目录读取 | 首次引导用户授权；可能触及"文件与文件夹"TCC |
| 读 `~/Library/Application Support/*` | 同上 | Kiro sqlite |
| 进程列表 | 无特殊（同用户进程可见） | `proc_listpids` 读自己用户的进程 |
| 聚焦终端窗口（M8） | **辅助功能 / Accessibility** | 可选；未授权则降级 |
| 系统通知 | 通知授权 | 首次弹窗 |

> 因需读取沙盒外用户文件，发布形态建议为 **Developer ID 签名 + notarized 的非 App Store 版本**（boring.notch 同此路线）；若上架 App Store 则需 security-scoped bookmark 让用户显式选目录。

---

## 9. 隐私与安全

- **全本地**：无任何网络出站；**不连接也不抢占** 本机 collector 端口，只读其落地文件。
- **只读最小权限**：仅读取所需文件；不请求超出必要范围的能力（首次需用户授予对 `~/.claude`、`~/.kiro`、`~/Library/Application Support` 的读取）。
- **敏感内容不持久化**：默认只存聚合指标（token 数、模型、时长），**不存** prompt / 代码内容（对标 Claude Code 的 `OTEL_LOG_USER_PROMPTS=0`）。可在设置中显式开启标题抓取。
- **符合生产安全规范**：不修改、不删除任何被监控工具的数据。

---

## 10. 开发路线图（里程碑）

| 阶段 | 内容 | 交付 |
|---|---|---|
| **M0 PoC（1–2 周）** | NSWindow 刘海覆盖 + 收起/展开动画；Claude Code JSONL tail 出 token 与模型 | 能在刘海看到 1 个工具的实时用量 |
| **M1 MVP（3–4 周）** | 状态机 + 任务完成通知；Token 聚合（今日/会话）；ClaudeCodeProvider 完整（M1+M2+M3+M6+M7） | P0 模块可用 |
| **M2 多 Agent（2–3 周）** | KiroProvider（JSONL+SQLite+lock）、AmazonQProvider（进程兜底）；多会话聚合视图 | 三工具并发监控 |
| **M3 报表与体验（2–3 周）** | 日/周/月报表（M5）、模型可视化（M4）、成本定价表、预算告警（M10）、快捷跳转（M8） | 对标 ccusage 的报表 |
| **M4 打磨发布** | 多屏/无刘海降级、自更新、通知规则、偏好设置（M9） | notarized DMG 发布 |

---

## 11. 风险与未决项

| 风险 / 未决 | 说明 | 缓解 |
|---|---|---|
| **Kiro token 字段未确认** | 本次勘探未在 `.jsonl` 样本行直接命中 `usage`；需从 `conversations_v2` 或 `data` 体解析 | M2 阶段对 SQLite 表结构 + jsonl `kind` 做专项逆向；先以进程/锁出状态，token 后补 |
| **Amazon Q 未安装** | 字段未知 | 安装后验证 `~/.aws/amazonq/` 结构；先进程兜底 |
| **OTel 落地文件路径依配置而定** | `file/logs` 的落地路径由环境变量 `CAKE_OTEL_LOG` 指定 | 启动时由用户用 CAKE_OTEL_LOG 指定，未配置则退回 JSONL |
| **各工具升级改格式** | JSONL/表结构可能变 | Provider 版本化解析 + 解析失败降级到进程探测；不强依赖单一字段 |
| **"等待输入"误判** | 启发式可能把"思考慢"误判为等待 | 多信号融合（OTel 心跳 + 进程状态 + token 停滞时长阈值可调） |
| **OTel 端口被占用/不可绑定** | OTLP 端口已被本机 collector 占用 | 改为读落地文件（C2），不绑端口 |
| **刘海窗口与其它刘海 App 冲突** | 同时装 boring.notch 等会争抢区域 | 检测冲突并提示；提供"仅胶囊模式"回退 |
| **全屏 / 多 Space** | 全屏下刘海被遮 | `fullScreenAuxiliary` + 降级为通知中心提醒 |
| **TCC 文件权限被拒** | 用户不授权主目录读取 | 引导页解释 + 降级为仅进程级监控 |

---

## 12. 附录：本机勘探速查

```
# Claude Code
~/.claude/projects/<工程转义>/<sessionId>.jsonl   # assistant 行含 message.usage{input/output/cache, model}
~/.claude/history.jsonl                           # display/timestamp/project/sessionId
OTel 落地日志（可选，CAKE_OTEL_LOG 指定）   # api_request 事件；只读 tail，不绑端口
进程: …/claude （命令行含模型配置）

# Kiro CLI
~/.kiro/sessions/cli/<id>.{json,jsonl,history,lock}   # .json: session_state 等; .jsonl: {version,kind,data}; .lock=活跃
~/Library/Application Support/kiro-cli/data.sqlite3   # 表: conversations_v2/conversations/history/state
~/.kiro/logs/<ts>/{kiro,mcp,powers}.log
# Kiro IDE(Electron): ~/Library/Application Support/Kiro/  (state.vscdb / ItemTable)

# Amazon Q CLI  (本机未安装: `q not found`)
~/.aws/amazonq/   (约定，安装后验证)

# 环境: macOS 26.5 Tahoe / Apple M3 Pro / 带刘海 Liquid Retina XDR 3456x2234
```

---

*本报告基于 2026-06-17～18 在目标机器上的实际数据源勘探撰写。竞品技术细节来自公开仓库（boring.notch、ccusage 等）。标注"约定/待验证"的部分需在对应工具安装或进入相应开发阶段后核实。*
