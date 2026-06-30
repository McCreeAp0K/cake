#!/usr/bin/env bash
# Cake 权限审批 hook 配置脚本（不编译、不需要 Xcode）。
#
# 给 Claude Code 与 Codex CLI 配置 PermissionRequest hook，指向 approve.sh。
# 配好后：Agent 需要权限确认时，请求会发到正在运行的 Cake（127.0.0.1:4319），
# 由刘海弹「允许/拒绝」。
#
# 可在两处运行，自动定位 approve.sh：
#   - 源码仓库根目录：用 ./hooks/approve.sh
#   - .app 内（Cake.app/Contents/Resources/）：用同级 hooks/approve.sh
#
# 用法：    ./install-hooks.sh
# 卸载：    ./install-hooks.sh --uninstall

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 定位 hooks 目录：优先脚本同级 hooks/，否则 .app 的 Resources/hooks/。
if [ -d "$HERE/hooks" ]; then
    HOOK_DIR="$HERE/hooks"
elif [ -d "$HERE/../Resources/hooks" ]; then
    HOOK_DIR="$(cd "$HERE/../Resources/hooks" && pwd)"
else
    echo "❌ 找不到 hooks 目录（应在 ./hooks/ 或 .app 的 Resources/hooks/ 下）"; exit 1
fi
HOOK="$HOOK_DIR/approve.sh"           # PermissionRequest 审批 hook
REGISTER="$HOOK_DIR/register.sh"      # SessionStart/UserPromptSubmit 会话→tty 注册 hook（B 方案）
NOTIFY="$HOOK_DIR/notify-state.sh"    # Stop/PreToolUse/Notification 状态事件 hook（hook 驱动状态流转）
[ -f "$HOOK" ] || { echo "❌ 找不到 approve.sh"; exit 1; }
chmod +x "$HOOK" "$REGISTER" "$NOTIFY" 2>/dev/null || true

CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CODEX_DIR="$HOME/.codex"
CODEX_HOOKS="$CODEX_DIR/hooks.json"

UNINSTALL=0
[ "${1:-}" = "--uninstall" ] && UNINSTALL=1

# ---------- Claude Code ----------
configure_claude() {
  python3 - "$CLAUDE_SETTINGS" "$HOOK" "$UNINSTALL" "$REGISTER" "$NOTIFY" <<'PY'
import json, sys, os
settings, hook, uninstall, register, notify = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4], sys.argv[5]
if not os.path.exists(settings) and uninstall:
    print("  Claude: 无 settings.json，跳过"); sys.exit(0)
os.makedirs(os.path.dirname(settings), exist_ok=True)
cfg = json.load(open(settings)) if os.path.exists(settings) else {}
hooks = cfg.setdefault("hooks", {})
# 先清掉旧的 approve.sh / register.sh / notify-state.sh（任何事件），保证幂等
CAKE_SCRIPTS = ("approve.sh", "register.sh", "notify-state.sh")
for ev in list(hooks.keys()):
    hooks[ev] = [g for g in hooks[ev]
                 if not any(any(s in h.get("command","") for s in CAKE_SCRIPTS)
                            for h in g.get("hooks", []))]
    if not hooks[ev]: del hooks[ev]
if not uninstall:
    # matcher 空字符串 = 匹配【所有工具】：Edit/Write/Read/WebFetch/MCP 等的权限请求也经 Cake
    # 审批，使刘海勾选「自动」（按工程目录信任）对该目录下所有工具生效，而非只 Bash。
    # approve.sh + server 对非 Bash 工具同样处理：自动批准只看 cwd（工具无关），未勾选则照常
    # 弹刘海，summarize 对未知工具回退显示工具名。
    hooks.setdefault("PermissionRequest", []).append({
        "matcher": "",
        "hooks": [{"type": "command", "command": hook, "timeout": 120}]
    })
    # 会话→tty 注册（B 方案）：SessionStart 建立映射，UserPromptSubmit 兜底刷新
    # （tty 极少变；但会话恢复/重连时 SessionStart 可能不再触发，靠每轮提交补一次）。
    reg_group = {"hooks": [{"type": "command", "command": register, "timeout": 5}]}
    hooks.setdefault("SessionStart", []).append(reg_group)
    hooks.setdefault("UserPromptSubmit", []).append(reg_group)
    # 状态事件（hook 驱动状态流转）：start=开始干活，stop=一轮结束，notify=需关注。
    # 每个事件配一个 notify-state.sh，传对应事件名，让刘海状态近实时收敛。
    def notify_group(ev_name):
        return {"hooks": [{"type": "command", "command": f"{notify} {ev_name}", "timeout": 5}]}
    hooks.setdefault("UserPromptSubmit", []).append(notify_group("start"))
    hooks.setdefault("PreToolUse", []).append(notify_group("start"))
    hooks.setdefault("Stop", []).append(notify_group("stop"))
    hooks.setdefault("Notification", []).append(notify_group("notify"))
    print("  Claude: 已配置 审批 + 会话注册 + 状态事件(UserPromptSubmit/PreToolUse/Stop/Notification)")
else:
    print("  Claude: 已移除")
json.dump(cfg, open(settings, "w"), indent=4, ensure_ascii=False)
PY
}

# ---------- Codex CLI ----------
configure_codex() {
  mkdir -p "$CODEX_DIR"
  python3 - "$CODEX_HOOKS" "$HOOK" "$UNINSTALL" <<'PY'
import json, sys, os
path, hook, uninstall = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
cfg = {}
if os.path.exists(path):
    try: cfg = json.load(open(path))
    except Exception: cfg = {}
# Codex hooks.json 顶层即各事件（与 inline [hooks] 表对应）
pr = cfg.get("PermissionRequest", [])
pr = [g for g in pr if not any("approve.sh" in h.get("command","") for h in g.get("hooks", []))]
if not uninstall:
    pr.append({
        "matcher": "^Bash$",
        "hooks": [{"type": "command", "command": hook, "timeout": 120}]
    })
    cfg["PermissionRequest"] = pr
    print("  Codex: 已配置 PermissionRequest(^Bash$) → " + path)
else:
    if pr: cfg["PermissionRequest"] = pr
    elif "PermissionRequest" in cfg: del cfg["PermissionRequest"]
    print("  Codex: 已移除")
json.dump(cfg, open(path, "w"), indent=2, ensure_ascii=False)
PY

  # Codex 需在 config.toml 开启 features.hooks=true
  CONFIG_TOML="$CODEX_DIR/config.toml"
  if [ "$UNINSTALL" = "0" ]; then
    if [ ! -f "$CONFIG_TOML" ] || ! grep -qE '^\s*hooks\s*=\s*true' "$CONFIG_TOML" 2>/dev/null; then
      if ! grep -q '\[features\]' "$CONFIG_TOML" 2>/dev/null; then
        printf '\n[features]\nhooks = true\n' >> "$CONFIG_TOML"
      else
        # 已有 [features] 段，在其后插入 hooks=true（若没有）
        printf '\nhooks = true\n' >> "$CONFIG_TOML"
      fi
      echo "  Codex: 已在 config.toml 启用 features.hooks=true"
    else
      echo "  Codex: features.hooks 已启用"
    fi
  fi
}

echo "==> approve.sh: $HOOK"
echo "==> 配置 Claude Code …"; configure_claude
echo "==> 配置 Codex CLI …";  configure_codex
echo
if [ "$UNINSTALL" = "0" ]; then
  echo "✅ hook 配置完成。需满足两个条件审批才生效："
  echo "   1) Cake 正在运行（提供 127.0.0.1:4319 审批服务）"
  echo "   2) 用【新启动】的 Claude/Codex 会话（已开的需重启）"
else
  echo "✅ 已卸载 Cake 的审批 hook。"
fi
