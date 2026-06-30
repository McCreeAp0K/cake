#!/usr/bin/env bash
# Cake 会话注册 hook（B 方案）。
#
# 在 SessionStart（及每次 UserPromptSubmit，作刷新兜底）时，把本会话的 session_id 与
# 控制终端 tty 上报给 Cake 本地 server（127.0.0.1:<port>/register），建立 sessionId↔tty
# 的【直接】映射。这样 Cake 跳转/在场判定不再依赖 cwd——彻底避免"同目录多会话""会话
# cd 互换目录"导致的 tty 绑错、刘海两个 agent 信息对调。
#
# tty 取自父进程（调用本 hook 的 claude 进程）的控制终端；hook 自身 stdin 非终端，
# 故不能用 `tty`，须 `ps -o tty= -p $PPID`。无控制终端（??）时不上报。
#
# 非阻塞、尽力而为：失败/无 server 直接静默退出，绝不影响会话。契约：stdout 输出空即可。

input="$(cat)"

# 从 hook JSON 取 session_id。提取后只保留 UUID 合法字符集（十六进制+连字符），
# 防 session_id 含引号/反斜杠时破坏下面拼出的 JSON。
sid="$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 | tr -dc 'a-fA-F0-9-')"
[ -z "$sid" ] && exit 0

# 父进程（claude）的控制终端，形如 ttys001。
tty_name="$(ps -o tty= -p "$PPID" 2>/dev/null | tr -d ' ')"
[ -z "$tty_name" ] && exit 0
[ "$tty_name" = "??" ] && exit 0

# 端口：与 approve.sh 一致，读 ~/.cake/port，缺失回落 4319。
PORT_FILE="$HOME/.cake/port"
PORT=4319
if [ -r "$PORT_FILE" ]; then
  p="$(head -1 "$PORT_FILE" | tr -dc '0-9')"   # 只取第一行，防多行/残留拼出非法端口
  [ -n "$p" ] && PORT="$p"
fi

curl -s --noproxy localhost --max-time 2 \
  -X POST "http://127.0.0.1:$PORT/register" \
  -H 'Content-Type: application/json' \
  --data-binary "{\"session_id\":\"$sid\",\"tty\":\"$tty_name\"}" >/dev/null 2>&1

exit 0
