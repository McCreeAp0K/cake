#!/usr/bin/env bash
# Cake PermissionRequest 审批 hook。
#
# Claude Code 在【真要弹权限对话框】时（即命令不在白名单、需用户手动确认）调用本脚本并阻塞等待。
# 白名单/规则自动放行的命令不会触发 PermissionRequest，因此刘海只在"需要你手动选择"时才弹。
#
# 脚本把 PermissionRequest 的 JSON 透传给 Cake 本地审批 server（127.0.0.1:<port>/approve），
# 该请求一直挂起，直到用户在刘海点"允许/拒绝"，server 才返回决策 JSON。
# 端口从 ~/.cake/port 读取（Cake 绑定成功后写入实际端口；4319 被占时会回退到其它端口）。
#
# 失败兜底（fail-safe）：Cake 没在跑 / 超时 / 出错 → 输出空 + exit 0，
# 落回 Claude 自己的交互式权限对话框，绝不静默放行也不卡死。
#
# 契约：stdout 输出 hookSpecificOutput.decision.behavior (allow/deny)，exit 0。

input="$(cat)"

# 审批端口：优先读 Cake 写的端口文件（~/.cake/port），它记录实际绑定端口——
# 4319 被占用时 Cake 会自动回退到下一个可用端口并写在这里。文件缺失/无效时回落 4319。
PORT_FILE="$HOME/.cake/port"
PORT=4319
if [ -r "$PORT_FILE" ]; then
  p="$(head -1 "$PORT_FILE" | tr -dc '0-9')"   # 只取第一行，防多行/残留拼出非法端口
  [ -n "$p" ] && PORT="$p"
fi

# 先健康探测：发正式审批请求前用极短超时 ping 一下。
# 为什么必须探测：/approve 会在 server 端挂起等用户点击（可能几分钟），无法靠它的
# 超时判断 server 是否在线；而若端口被无关程序占着（只 listen 不响应），直接发
# /approve 会干等到 --max-time(110s) 才超时，每次权限确认都卡近 2 分钟。
# /ping 由 Cake 立即回 200：探测失败（连不上 / 非 Cake 占用 / 无响应）就秒级落回原生对话框。
if ! curl -s --noproxy localhost --max-time 2 \
     "http://127.0.0.1:$PORT/ping" 2>/dev/null | grep -q '"ok"'; then
  exit 0   # Cake 审批服务不可用 → fail-safe，落回 Claude 原生权限对话框
fi

# --max-time 须小于 settings.json 里配置的 hook timeout，保证能干净返回。
resp=$(printf '%s' "$input" | curl -s --noproxy localhost --max-time 110 \
  -X POST "http://127.0.0.1:$PORT/approve" \
  -H 'Content-Type: application/json' --data-binary @- 2>/dev/null)

if [ -z "$resp" ]; then
  # server 不可用 / 超时 → 输出空，落回 Claude 正常权限对话框。
  exit 0
fi

# server 已返回完整的 hookSpecificOutput JSON，原样转发。
printf '%s\n' "$resp"
exit 0
