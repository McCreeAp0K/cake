# Cake

常驻 macOS 刘海区域的本地 AI Agent 监控中枢。把 Claude Code 等 AI 编码 Agent 的
运行状态、token 用量、模型选择、后台任务进度，聚合到刘海"灵动岛"里，并支持
**权限审批**——Agent 需要确认时，直接在刘海点允许/拒绝。

> 纯客户端、无后端、本地只读、零侵入。详见
> [技术实现报告](AI-Agent-灵动岛监控App-技术实现报告.md)。

## 功能

- **常态刘海**：🦁 logo + 后台运行 agent 数量 + 累计 token。
- **下拉展开**（三种触发：任务完成 / 需要权限 / 点击 logo）：显示各会话状态、
  模型、token、正在运行的内容；点会话行跳转到对应终端窗口。
- **权限审批**：Agent 触发权限确认时，刘海下拉弹出该任务正在执行的命令 +
  `拒绝 / 终端 / 允许` 三个按钮。多个请求竖向同时堆叠，处理一条抹除一条。

## 环境要求

- macOS 14 Sonoma+（带刘海屏最佳；无刘海降级为顶部胶囊）
- Swift 6 / Xcode 26+
- Claude Code（通过 OTel 遥测与会话 JSONL 采集数据）

## 安装

在仓库根目录运行：

```bash
./install.sh
```

脚本会：
1. `swift build -c release` 构建可执行文件；
2. 把 `PermissionRequest(Bash)` hook 幂等写入 `~/.claude/settings.json`，
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
- `--scan` / `--scan-otel`：无窗口模式，命令行打印各会话 token 解析结果（验证数据层）。

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
Claude 要执行 Bash（且不在白名单）
   → PermissionRequest hook 调用 hooks/approve.sh（阻塞等待）
   → approve.sh POST 到 Cake 本地 server (127.0.0.1:4319/approve)
   → 刘海下拉显示命令 + 允许/拒绝
   → 用户点击 → server 返回 decision.behavior → Claude 据此执行/阻止
```

- 只拦 `Bash`，且仅在 Claude **本就要弹权限对话框**时触发——白名单自动放行的
  命令不会打扰你（依赖 Claude Code 的 `PermissionRequest` 事件）。
- **Fail-safe**：Cake 未运行 / 超时 → approve.sh 落回 Claude 自己的
  交互式权限对话框，绝不静默放行，也不卡死。
- 审批 server 监听本地端口 4319。

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

| 工具 | 数据源 | 状态 |
|---|---|---|
| **Claude Code** | `~/.claude/projects/*.jsonl`（+ 可选 OTel 落地日志） | ✅ 完整实测 |
| **Codex** (OpenAI) | `~/.codex/sessions/*.jsonl`（`CODEX_HOME` 可改） | ⚠️ 按 ccusage 格式实现，待真实数据实测 |

> 新增 agent 只需写一个 `AgentProvider`，核心层（聚合/状态机/UI/审批）全部复用。

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
hooks/approve.sh   PermissionRequest hook 脚本
install.sh         构建 + 配置 hook
```
