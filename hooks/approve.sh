#!/usr/bin/env bash
# Cake PermissionRequest 审批 hook。
#
# Claude Code 在【真要弹权限对话框】时（即命令不在白名单、需用户手动确认）调用本脚本并阻塞等待。
# 白名单/规则自动放行的命令不会触发 PermissionRequest，因此刘海只在"需要你手动选择"时才弹。
#
# 脚本把 PermissionRequest 的 JSON 透传给 Cake 本地审批 server（127.0.0.1:4319/approve），
# 该请求一直挂起，直到用户在刘海点"允许/拒绝"，server 才返回决策 JSON。
#
# 失败兜底（fail-safe）：Cake 没在跑 / 超时 / 出错 → 输出空 + exit 0，
# 落回 Claude 自己的交互式权限对话框，绝不静默放行也不卡死。
#
# 契约：stdout 输出 hookSpecificOutput.decision.behavior (allow/deny)，exit 0。

input="$(cat)"

# --max-time 须小于 settings.json 里配置的 hook timeout，保证能干净返回。
resp=$(printf '%s' "$input" | curl -s --noproxy localhost --max-time 110 \
  -X POST http://127.0.0.1:4319/approve \
  -H 'Content-Type: application/json' --data-binary @- 2>/dev/null)

if [ -z "$resp" ]; then
  # server 不可用 / 超时 → 输出空，落回 Claude 正常权限对话框。
  exit 0
fi

# server 已返回完整的 hookSpecificOutput JSON，原样转发。
printf '%s\n' "$resp"
exit 0
