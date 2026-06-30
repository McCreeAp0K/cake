# Cake

常驻 macOS 刘海区域的本地 AI Agent 监控中枢。把 Claude Code 等 AI 编码 Agent 的
运行状态、token 用量、模型选择、后台任务进度，聚合到刘海"灵动岛"里，并支持
**权限审批**——Agent 需要确认时，直接在刘海点允许/拒绝。

> 纯客户端、无后端、本地只读、零侵入。详见
> [技术实现报告](AI-Agent-灵动岛监控App-技术实现报告.md)。

## 功能

- **多 Agent 监控**：同时监控 **Claude Code、Codex、Kiro CLI** 的运行状态、模型、
  用量（Claude/Codex 为 token+成本，Kiro 为 credits）、正在运行的内容。
- **常态刘海**：🍰 logo + 后台运行 agent 数量 + 累计 token。
- **下拉展开**（三种触发：任务完成 / 需要处理 / 点击 logo）：显示各会话状态、
  模型、用量；点会话行右侧图标跳转到对应终端窗口。每行两行排布：
  - 第一行：**所在文件夹** + **agent logo**（Claude/Codex/Kiro/Amazon Q 品牌图标）+ 自动勾选 + 用量 + 跳转；
  - 第二行：**模型** + **正在执行的任务**。
- **待处理区**（统一展示需要你处理的事项）：
  - **权限审批**：弹出待执行的操作（命令 / 文件编辑 / 抓取等）+ `拒绝 / 终端 / 允许` 三按钮，多请求竖向堆叠、逐条处理。
  - **等待输入**：`⏸ 等待你操作` + 终端跳转按钮（agent 答完一轮等你输入时提醒）。
- **自动批准**：每个 agent 行可勾选「自动」（按**工程目录**信任），勾上后该目录**及其所有
  子目录**的权限请求自动放行、不再弹刘海；不勾则保持下拉审批。勾选状态是内存态，重启 Cake 后清空。
- **开机自启**：展开面板底部可开关（`SMAppService`）；也可命令行 `Cake --unregister-login` 注销当前二进制注册的登录项。

## 下载安装（普通用户，无需编程）

1. 打开 [**Releases**](https://github.com/McCreeAp0K/cake/releases/latest)，下载 `Cake.app.zip`。
2. 双击解压，把 **Cake.app** 拖进「应用程序」。
3. 双击启动。刘海会出现 🍰 + 后台 agent 数 + token。

> **首次启动被拦截？** 本版本为 ad-hoc 签名、未做 Apple 公证，macOS 可能提示
> "无法打开"。到 **系统设置 → 隐私与安全性**，在下方点 **「仍要打开」** 即可。
> 也可在终端执行 `xattr -dr com.apple.quarantine /Applications/Cake.app` 解除限制。

### 启用权限审批（可选，无需 Xcode）

下载版默认开箱即用的是**监控功能**。若想用**权限审批**（Agent 要执行需确认的操作时刘海弹
允许/拒绝），跑一次内置的配置脚本即可，**不需要编译/Xcode**：

```bash
/Applications/Cake.app/Contents/Resources/install-hooks.sh
```

它会给 **Claude Code 和 Codex** 都配好 hook：`PermissionRequest` 指向 `approve.sh`（审批），
`SessionStart`/`UserPromptSubmit` 指向 `register.sh`（上报会话↔终端映射）。
之后保持 Cake 运行、用新启动的 Claude/Codex 会话即可。卸载：脚本加 `--uninstall`。

## 卸载

Cake 会在系统里留下四处痕迹：App 本体、开机自启登录项、hook 配置、端口文件。完整卸载：

**1. 退出 App**：点刘海下拉面板底部「退出」，或在活动监视器结束 Cake 进程。

**2. 移除 hook 配置**（若启用过权限审批）：

```bash
/Applications/Cake.app/Contents/Resources/install-hooks.sh --uninstall
```

幂等地从 `~/.claude/settings.json`、`~/.codex/hooks.json` 移除 Cake 的审批/注册 hook。
（若已先删 App，可手动编辑这两个文件，删掉 `command` 指向 `approve.sh` / `register.sh` 的条目。）

**3. 注销开机自启**（删 App 前执行，用 App 自身身份注销最干净）：

```bash
/Applications/Cake.app/Contents/MacOS/Cake --unregister-login
```

若已删 App 才想起：到 **系统设置 → 通用 → 登录项与扩展**，手动移除 Cake。

**4. 删除 App 与残留文件**：

```bash
rm -rf /Applications/Cake.app   # 或你放 Cake.app 的实际位置
rm -rf ~/.cake                  # 端口文件
```

## 升级到新版本（先完全卸载旧版，再装新版）

> 直接用新版覆盖旧版**不够**：旧版进程可能还在后台跑（单实例锁会让新版"已在运行，
> 本次启动退出"而装了等于没换），旧 `.app` 也可能散落在多个位置（`/Applications`、
> 你当初解压的下载目录、或源码仓库的 `dist/`）。请按下面顺序**先彻底清掉旧版，再装新版**。

### 第一步：完全卸载旧版

**1. 退出所有运行中的 Cake**（务必先做，否则单实例锁会拦截新版）：

```bash
# 点刘海下拉面板底部「退出」，或命令行强制结束所有 Cake 进程：
pkill -x Cake
```

**2. 注销开机自启**（用旧二进制自身身份注销最干净，删 App 前执行）：

```bash
# 路径按你旧版实际位置；下载版在 /Applications，源码版在仓库 dist/
/Applications/Cake.app/Contents/MacOS/Cake --unregister-login 2>/dev/null
```

若已找不到旧二进制：到 **系统设置 → 通用 → 登录项与扩展** 手动移除 Cake。

**3. 删除所有旧 `.app`**（逐个排查可能的位置，全删）：

```bash
rm -rf /Applications/Cake.app
rm -rf ~/Downloads/Cake.app          # 当初从 zip 解压的位置（按实际改）
# 源码用户另有一份在仓库 dist/Cake.app，按需删
```

不确定旧版藏在哪？用这条找出所有 Cake.app：

```bash
mdfind -name 'Cake.app' 2>/dev/null; ls -d /Applications/Cake.app ~/Downloads/Cake.app 2>/dev/null
```

**4. 清掉端口文件**（旧 server 的残留，避免 hook 连到失效端口）：

```bash
rm -rf ~/.cake
```

> **hook 配置一般不用动**：`~/.claude/settings.json` / `~/.codex/hooks.json` 里的 hook 指向
> `approve.sh` / `register.sh` 等脚本路径。**只要新版 `.app` 放在和旧版相同的位置**，路径不变、
> 无需重配。若新版换了安装位置（脚本随 `.app` 内的 `Resources/` 一起搬了），装好后**重跑一次**
> `install-hooks.sh`（见下）即可让 hook 指向新路径。

### 第二步：安装新版

1. 打开 [**Releases**](https://github.com/McCreeAp0K/cake/releases/latest)，下载最新的 `Cake.app.zip`。
2. 双击解压，把 **Cake.app** 拖进「应用程序」（覆盖时选「替换」）。
3. 首次启动若被 Gatekeeper 拦截：**系统设置 → 隐私与安全性** 点「仍要打开」，或
   `xattr -dr com.apple.quarantine /Applications/Cake.app`。
4. 双击启动。刘海重新出现 🍰。

**装好后（若启用过权限审批 / 换了安装位置）重新配 hook**：

```bash
/Applications/Cake.app/Contents/Resources/install-hooks.sh
```

> **注意：勾选的「自动批准」会丢失**。自动批准的受信目录是**内存态**，不写盘——每次重启
> Cake（含本次升级）都会清空。新版起来后，在对应会话行**重新勾一次「自动」**即可。
> 新版的自动批准对受信目录**及其所有子目录**都生效（即使 agent `cd` 进了子目录也自动放行）。

### 源码用户的升级

在仓库根目录拉最新代码后重新构建打包即可：

```bash
git pull
pkill -x Cake                      # 先退出旧版
./bundle.sh --install              # 构建 release + 生成 .app 并复制到 /Applications
open /Applications/Cake.app
```

## 环境要求

- **下载版**：macOS 14 Sonoma+（带刘海屏最佳；无刘海降级为顶部条）。
- **从源码构建**：另需 Swift 6 / Xcode 26+。
- 监控对象：Claude Code（会话 JSONL，OTel 实时遥测可选）、Codex。

## 从源码构建（开发者 / 需要权限审批）

clone 后在仓库根目录运行：

```bash
git clone https://github.com/McCreeAp0K/cake.git
cd cake
./install.sh
```

脚本会：
1. `swift build -c release` 构建可执行文件；
2. 把 `PermissionRequest` hook（匹配所有工具）幂等写入 `~/.claude/settings.json`，
   指向本仓库的 `hooks/approve.sh`（路径按本机仓库位置自动解析）。

> hook 仅在**新启动**的 Claude Code 会话生效；已开的会话需重启。

卸载 hook：

```bash
./install.sh --uninstall
```

## 运行

命令行直接运行：

```bash
.build/release/Cake
```

- 无 Dock 图标（`LSUIElement`），常驻刘海。
- `--demo`：启动后模拟一次任务完成下拉，用于查看动画。
- `--scan` / `--scan-otel` / `--scan-codex` / `--scan-kiro`：无窗口模式，命令行打印对应工具各会话用量解析结果（验证数据层）。
- `--unregister-login`：以当前可执行文件身份调用 `SMAppService.mainApp.unregister()`，注销本二进制注册的开机自启登录项后退出（用于清理残留的登录项，例如直接从 `.build` 产物注册过自启时）。

## 打包成 .app（可双击运行）

```bash
./bundle.sh            # 生成 dist/Cake.app
./bundle.sh --install  # 生成并复制到 /Applications
```

- 生成标准 macOS `.app` bundle，可在访达/启动台双击运行。
- 无 Developer ID 签名时用 **ad-hoc 签名**：本机可运行；首次启动若被 Gatekeeper
  拦截，在「系统设置 > 隐私与安全性」点「仍要打开」即可。
- 要让别人无障碍分发安装，需 Developer ID 签名 + 公证（notarize）。

## 权限审批工作原理

```
Agent 要执行某工具（且不在白名单，本就要弹权限对话框）
   → PermissionRequest hook 调用 approve.sh（阻塞等待）
   → approve.sh POST 到 Cake 本地 server（端口见下，从 ~/.cake/port 读取）
   → 刘海下拉显示操作 + 允许/拒绝
   → 用户点击 → server 返回 decision.behavior → Agent 据此执行/阻止
```

- **Claude Code 与 Codex 共用同一套**：两者的 `PermissionRequest` hook 契约一致
  （`decision.behavior` = allow/deny），同一个 `approve.sh` + 同一个 server 通吃。
  - Claude 配置在 `~/.claude/settings.json`
  - Codex 配置在 `~/.codex/hooks.json` + `config.toml` 的 `features.hooks = true`
- **拦截范围**：Claude Code 拦**所有工具**（Bash/Edit/Write/Read/WebFetch/MCP 等，hook
  matcher 为空=匹配全部）；Codex 目前仅拦 `Bash`。两者都**仅在 Agent 本就要弹权限对话框**时
  触发——白名单自动放行的操作不会打扰你。
- **Fail-safe**：Cake 未运行 / 服务不可用 → approve.sh 落回 Agent 自己的
  交互式权限对话框，绝不静默放行，也不卡死。发正式审批请求前会先用 2 秒超时
  探测 `/ping`，服务不在线就**秒级**落回原生对话框，不会傻等到 110 秒超时。
- **自动批准**：在刘海会话行勾选「自动」（按**工程目录**信任），该目录的权限请求直接放行、不弹刘海。
  匹配按**归一化 cwd 的路径前缀**：受信目录**本身或其任意层子目录**都放行——会话 `cd` 进子目录、
  或工具在子目录里执行命令时，hook 报的 cwd 是子路径，前缀匹配仍能命中（精确相等会失配、勾了仍弹）。
  归一化解析软链/去尾斜杠，并用 `/` 收尾比较，避免 `/foo` 误命中兄弟目录 `/foobar`。
  勾选状态是内存态、不写盘，重启 Cake 后需重新勾选。
- **审批移除**：以下任一情况，刘海对应审批自动消失——
  - hook 进程被 kill（curl 连接断开）；
  - 你**在终端里**直接答复（监视会话 transcript 的 tool_result，据 is_error 还原 allow/deny）。
- **端口自适应**：审批 server 默认监听 `4319`，被占用时在 `4319–4328` 内自动回退到下一个
  可用端口；若这 10 个端口**全被占用**，则交由系统**动态分配任意可用端口**作兜底（几乎不会失败）。
  实际端口写入 `~/.cake/port`，hook（approve.sh / register.sh）读该文件决定连哪个端口，
  因此无论落在哪个端口都能正常工作。
- **会话→终端映射**：`register.sh`（SessionStart/UserPromptSubmit hook）上报 `session_id↔tty`，
  让"跳转终端 / 在场判定"不依赖 cwd，避免同目录多会话、`cd` 互换目录时绑错终端。
- **hook 驱动状态流转**：`notify-state.sh`（UserPromptSubmit/PreToolUse/Stop/Notification hook）
  在状态关键节点 POST `/event` 给 Cake，触发一次【即时重扫】——Stop 到达时 JSONL 刚写好
  `end_turn`，立即重扫即可马上判完成，状态流转近实时，无需等轮询。hook 是主路径，轮询降到
  3s 仅作兜底（进程被强杀不发 Stop、未装 hook 的会话、Kiro 无此套 hook、按时间收敛等待输入）。
  状态判定仍用既有 `stop_reason`/进程存活逻辑（单一真相源），hook 只改"触发时机"。

## 实时遥测（可选）

核心数据来自会话 JSONL（所有 Claude Code 通用）。若你的 Claude Code 配置了把
OTel 日志落地成本地 JSON 文件，可设环境变量让 Cake 读取以获得更实时的 token/成本：

```bash
export CAKE_OTEL_LOG=/path/to/your/otel-log.json
```

未设置时自动退回 JSONL，不影响功能。

## 权限授权

- **终端跳转**需要"自动化"权限：首次点击会话行跳转时，macOS 会弹窗请求授权
  Cake 控制 Terminal/iTerm，点**允许**即可。
- 若误点了"不允许"，跳转会静默退回到打开 Finder。到
  **系统设置 → 隐私与安全性 → 自动化** 重新勾选 Cake 下的终端 App 即可恢复。
- 终端跳转目前支持 **Terminal.app 与 iTerm2**；其它终端（Warp/VSCode/Ghostty 等）
  会降级为在 Finder 打开工程目录。

## 支持的 Agent

| 工具 | 数据源 | 用量 | 权限审批 | 状态 |
|---|---|---|---|---|
| **Claude Code** | `~/.claude/projects/*.jsonl`（+ 可选 OTel 落地日志） | token + 成本 | ✅ | ✅ 完整实测 |
| **Codex** (OpenAI) | `~/.codex/sessions/*.jsonl`（`CODEX_HOME` 可改） | token + 成本 | ✅ | ⚠️ 按 ccusage 格式实现，待真机实测 |
| **Kiro CLI** | `~/.kiro/sessions/cli/<id>.{json,jsonl,lock}` | credits（无 token 原始数）| 待接 | ✅ 完整实测 |

> 新增 agent 只需写一个 `AgentProvider`，核心层（聚合/状态机/UI/审批）全部复用。
> 权限审批对 **Claude Code 与 Codex** 生效（PermissionRequest hook 契约一致）。

## 数据来源（纯本地只读）

| 数据 | 来源 |
|---|---|
| token / 模型 / 成本 | 各 agent 会话 JSONL（Claude 另支持可选 OTel 实时遥测） |
| 会话活跃度 / 状态 | 会话活动时间 + 进程探测（libproc） |
| 终端跳转 | 进程 tty ↔ Terminal.app / iTerm2 标签匹配（AppleScript） |
| 权限请求 | Claude Code `PermissionRequest` hook |

## 许可证

[MIT](LICENSE) © McCreeAp0K

## 项目结构

```
Sources/Cake/
  Models/      数据模型（会话快照、token、待批请求）
  Providers/   数据采集（OTel 日志 / JSONL / 进程探测）
  Core/        聚合、状态机、定价、审批 server
  UI/          刘海窗口、视图、提醒、终端跳转
Resources/agent-logos/   各 agent 品牌 logo（下拉栏第一行用）
hooks/approve.sh         PermissionRequest 审批 hook
hooks/register.sh        会话→tty 注册 hook（SessionStart/UserPromptSubmit）
install.sh               构建 + 配置 hook
```
