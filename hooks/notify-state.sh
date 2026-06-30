#!/usr/bin/env bash
# Cake 状态事件 hook（hook 驱动状态流转）。
#
# 在 Claude/Codex 的状态关键节点把事件上报给 Cake 本地 server（127.0.0.1:<port>/event），
# 让刘海状态【实时】收敛，不必等轮询周期。事件名由第一个参数传入：
#   start  —— UserPromptSubmit / PreToolUse：开始干活（→ running）
#   stop   —— Stop：一轮回答结束（→ done，此时 JSONL 已写好 end_turn）
#   notify —— Notification：需要权限 / 等待输入（→ 触发即时重扫）
#
# Cake 收到事件后并不直接覆盖状态，而是触发一次该来源的【即时重扫+重算】——沿用
# 既有的 stop_reason / 进程存活判定（单一真相源），只把"触发时机"从轮询改为 hook 驱动，
# 因此更实时，又不会与文件/进程判定打架。
#
# 非阻塞、尽力而为：失败 / 无 server 直接静默退出，绝不影响会话。契约：stdout 输出空即可。

event="${1:-start}"
input="$(cat)"

# 从 hook JSON 取 session_id（用于 Cake 定位是哪个会话）。
# 提取后只保留 UUID 合法字符集（十六进制 + 连字符）：既防 session_id 含引号/反斜杠时
# 破坏拼出的 JSON，又顺带过滤异常输入。为空（提取失败）直接退出，不发无意义请求。
sid="$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 | tr -dc 'a-fA-F0-9-')"
[ -z "$sid" ] && exit 0

# 端口：与 approve.sh / register.sh 一致，读 ~/.cake/port，缺失回落 4319。
PORT_FILE="$HOME/.cake/port"
PORT=4319
if [ -r "$PORT_FILE" ]; then
  p="$(head -1 "$PORT_FILE" | tr -dc '0-9')"   # 只取第一行，防多行/残留拼出非法端口
  [ -n "$p" ] && PORT="$p"
fi

curl -s --noproxy localhost --max-time 2 \
  -X POST "http://127.0.0.1:$PORT/event" \
  -H 'Content-Type: application/json' \
  --data-binary "{\"session_id\":\"$sid\",\"event\":\"$event\"}" >/dev/null 2>&1

exit 0
