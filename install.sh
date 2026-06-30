#!/usr/bin/env bash
# Cake 安装脚本
#
# 作用：
#   1. release 构建 Cake
#   2. 把 PermissionRequest(Bash) hook 幂等地写入 ~/.claude/settings.json，
#      指向本仓库的 hooks/approve.sh（路径按本机仓库位置自动解析，不硬编码）
#
# 用法：在仓库根目录运行  ./install.sh
# 卸载 hook：./install.sh --uninstall

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$REPO_DIR/hooks/approve.sh"
SETTINGS="$HOME/.claude/settings.json"

if [ "${1:-}" = "--uninstall" ]; then
  python3 - "$SETTINGS" <<'PY'
import json, sys, os
p = sys.argv[1]
if not os.path.exists(p):
    print("settings.json 不存在，无需卸载"); sys.exit(0)
cfg = json.load(open(p))
hooks = cfg.get("hooks", {})
for ev in ("PermissionRequest", "PreToolUse"):
    if ev in hooks:
        hooks[ev] = [g for g in hooks[ev]
                     if not any("approve.sh" in h.get("command","") for h in g.get("hooks", []))]
        if not hooks[ev]:
            del hooks[ev]
json.dump(cfg, open(p, "w"), indent=4, ensure_ascii=False)
print("已从 settings.json 移除 Cake hook")
PY
  echo "卸载完成。"
  exit 0
fi

echo "==> 构建 Cake (release)…"
( cd "$REPO_DIR" && swift build -c release )

echo "==> 确保 hook 可执行…"
chmod +x "$HOOK"

echo "==> 写入 PermissionRequest(Bash) hook 到 $SETTINGS …"
python3 - "$SETTINGS" "$HOOK" <<'PY'
import json, sys, os
settings, hook = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(settings), exist_ok=True)
cfg = json.load(open(settings)) if os.path.exists(settings) else {}
hooks = cfg.setdefault("hooks", {})

# 移除旧的 PreToolUse approve（历史方案），避免每条 Bash 都弹
if "PreToolUse" in hooks:
    hooks["PreToolUse"] = [g for g in hooks["PreToolUse"]
                           if not any("approve.sh" in h.get("command","") for h in g.get("hooks", []))]
    if not hooks["PreToolUse"]:
        del hooks["PreToolUse"]

# 幂等写入 PermissionRequest(Bash)
pr = hooks.setdefault("PermissionRequest", [])
already = any("approve.sh" in h.get("command","") for g in pr for h in g.get("hooks", []))
if not already:
    pr.append({
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": hook, "timeout": 120}]
    })
    json.dump(cfg, open(settings, "w"), indent=4, ensure_ascii=False)
    print("  已添加 PermissionRequest(Bash) ->", hook)
else:
    print("  hook 已存在，跳过")
PY

echo
echo "✅ 安装完成。"
echo "   启动监控：$REPO_DIR/.build/release/Cake"
echo "   提示：hook 在【新启动】的 Claude Code 会话中才生效；已开的会话需重启。"
