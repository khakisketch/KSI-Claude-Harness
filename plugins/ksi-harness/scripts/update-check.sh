#!/usr/bin/env bash
# SessionStart hook: 원격 최신 릴리스 태그(vX.Y.Z)와 설치된 ksi-harness 버전을 비교해
# 뒤처졌으면 '업데이트 가능' 1줄을 사용자에게 알린다. **알림-only — 코드를 자동으로 바꾸지 않는다.**
#   왜 자동적용 안 하나: 이 하네스는 dangerous mode(권한 프롬프트 off)로 돌 수 있어, 원격 코드를 검토 없이
#   자동 pull·실행하면 공급망 위험이다. 그래서 "새 버전 있다"만 알리고 적용은 사람이 한다.
# 두 모드 자동 감지(0.9.4):
#   · 플러그인 머신: ${CLAUDE_PLUGIN_ROOT} 설치본의 plugin.json version이 앵커 → 적용은 /plugin update.
#   · native 머신(~/.claude 직접 운용): ${KSI_HARNESS_REPO}(repo checkout 경로)의 plugin.json version이 앵커
#     → 적용은 sync-machine.sh --native. KSI_HARNESS_REPO 미설정 시 native는 조용히 skip(개인 경로를 dist에 박지 않는다).
# 릴리스 신호 = git 태그 vX.Y.Z (release 시 `git tag vX.Y.Z && git push --tags`).
# 설계(세션 시작을 느리게 하지 않는다): ① 하루 1회만 실제 네트워크 체크(throttle) ② git ls-remote 짧은 timeout
#   ③ 미설치·경로부재·git/python 부재·오프라인·태그 없음·비-semver 전부 graceful silent.
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"

# 모드 감지: CLAUDE_PLUGIN_ROOT 있으면 플러그인, 아니면 KSI_HARNESS_REPO(native).
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [ -n "$PLUGIN_ROOT" ]; then
  MODE=plugin; ANCHOR="$PLUGIN_ROOT"; manifest="$PLUGIN_ROOT/.claude-plugin/plugin.json"
else
  REPO="${KSI_HARNESS_REPO:-}"
  [ -n "$REPO" ] || exit 0                 # native인데 repo checkout 경로 미지정 → skip
  MODE=native; ANCHOR="$REPO"; manifest="$REPO/plugins/ksi-harness/.claude-plugin/plugin.json"
fi
[ -f "$manifest" ] || exit 0
command -v git >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# throttle: 하루(86400s) 1회만 실제 체크 — 대부분의 세션 시작은 즉시 통과(비용 0).
sentinel="${TMPDIR:-/tmp}/claude-ksi-update-check.last"
now="$(date +%s 2>/dev/null)"; : "${now:=0}"
if [ -f "$sentinel" ] && [ "$now" -gt 0 ]; then
  last="$(cat "$sentinel" 2>/dev/null)"; : "${last:=0}"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $((now - last)) -lt 86400 ] && exit 0
fi
printf '%s\n' "$now" > "$sentinel" 2>/dev/null || true

# 설치된 버전 (비-semver, 예: 버전 미설정 시 git SHA → 비교 불가, skip)
installed="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$manifest" 2>/dev/null)"
[ -n "$installed" ] || exit 0
case "$installed" in *[!0-9.]*|''|.*|*.) exit 0 ;; esac

# 원격 URL: 앵커가 git 클론 안이면 그 origin, 아니면 알려진 repo(이 플러그인의 home).
url="$(git -C "$ANCHOR" config --get remote.origin.url 2>/dev/null)"
[ -n "$url" ] || url="https://github.com/KhakiSkech/ksi-claude-harness.git"

# 최신 릴리스 태그 — 4s timeout, 실패(오프라인·auth·timeout)는 전부 silent.
command -v timeout >/dev/null 2>&1 && TO="timeout 4" || TO=""
tags="$($TO git ls-remote --tags "$url" 2>/dev/null)" || exit 0
latest="$(printf '%s\n' "$tags" | sed -n 's#.*refs/tags/v\([0-9][0-9.]*\)$#\1#p' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
[ -n "$latest" ] || exit 0

# latest > installed ?
newer="$(python3 -c '
import sys
def t(v): return tuple(int(x) for x in v.split("."))
try:
    print("1" if t(sys.argv[2]) > t(sys.argv[1]) else "0")
except Exception:
    print("0")
' "$installed" "$latest" 2>/dev/null)"
[ "$newer" = "1" ] || exit 0

if [ "$MODE" = plugin ]; then
  apply="검토 후 업데이트: /plugin marketplace update → /plugin update ksi-harness"
else
  apply="받기: cd \"$ANCHOR\" && bash scripts/sync-machine.sh --native"
fi
msg="ksi-harness v$latest 사용 가능 (설치됨 v$installed). $apply  (자동적용 안 함 — 알림-only)"
MSG="$msg" python3 -c '
import os, json
m = os.environ["MSG"]
print(json.dumps({
    "systemMessage": m,
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": "업데이트 알림(사용자에게 전달): " + m,
    },
}))
' 2>/dev/null
exit 0
