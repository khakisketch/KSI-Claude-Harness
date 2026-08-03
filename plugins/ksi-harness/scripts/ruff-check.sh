#!/usr/bin/env bash
# PostToolUse hook: .py 파일을 Edit/Write 하면 ruff check를 돌려 결과를 모델에 피드백한다.
# graceful skip: ruff가 없거나 .py가 아니거나 파일이 없으면 조용히 통과한다.
# 3-훅 게이트 대칭: 백엔드=정적 lint(이 훅, 자동 주입)+동작 넛지(backend-verify, Stop) / 프론트=시각+동선 넛지(ui-render, Stop).
# --no-cache: 훅의 CWD가 쓰기 불가일 수 있어(예: Windows 'Program Files') 캐시 생성 실패→lint 미검증이 되는 것을 방지.
set -uo pipefail

# 훅이 login shell의 full PATH를 상속 못할 수 있으므로 ruff 설치 경로를 보강
export PATH="$HOME/.local/bin:$PATH"

input="$(cat)"

# 편집된 파일 경로 추출 (tool_input.file_path / path 등 여러 스키마 대응)
file="$(printf '%s' "$input" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    ti = d.get("tool_input", {}) or {}
    print(ti.get("file_path") or ti.get("path") or ti.get("notebook_path") or "")
except Exception:
    print("")
' 2>/dev/null)"

[ -z "$file" ] && exit 0
case "$file" in
  *.py) ;;
  *) exit 0 ;;
esac

if ! command -v ruff >/dev/null 2>&1; then
  # ruff 미설치 → 지금까지 무음 스킵이었다(lint가 통째로 미검증인데 은폐). sca-check.sh의 '미검증 가시화' 패턴처럼
  # 1줄 통지하되, 세션당 1회만 — 기존 config-error dedup(L43-51류) sentinel 패턴을 세션 키로 재사용.
  sid="$(printf '%s' "$input" | python3 -c '
import sys, json
try:
    print(json.load(sys.stdin).get("session_id") or "nosession")
except Exception:
    print("nosession")
' 2>/dev/null)"
  sentinel="${TMPDIR:-/tmp}/claude-ruff-missing-${sid}.last"
  if [ ! -f "$sentinel" ]; then
    printf '1\n' > "$sentinel" 2>/dev/null || true
    python3 -c '
import json
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": "⚠ ruff 미설치 — lint 미검증. pip install ruff 후 다시 점검하세요."
    }
}))
' 2>/dev/null
  fi
  exit 0
fi
[ -f "$file" ] || exit 0

out="$(ruff check --no-cache "$file" 2>&1)"
rc=$?
[ $rc -eq 0 ] && exit 0   # 위반 없음

# ruff 자체 에러(config/internal, rc>=2): lint 위반이 아니라 헛수정은 막되, 침묵하지 않고
# 1줄 통지해 'lint 검증이 무력화됐음'을 가시화한다(설정 깨짐 은폐 방지).
if [ $rc -ge 2 ]; then
  # dedup: 같은 config/internal 에러를 매 .py 저장마다 반복 주입하지 않는다.
  # 동일 에러가 1시간 내 이미 통지됐으면 침묵; 새 작업세션·다른 에러면 다시 통지(은폐 방지).
  sentinel="${TMPDIR:-/tmp}/claude-ruff-cfgerr.last"
  h="$(printf '%s' "$out" | cksum | tr -d ' ')"
  now="$(date +%s 2>/dev/null)"; : "${now:=0}"   # date 실패 환경 방어(타이머 무력화 방지)
  if [ -f "$sentinel" ]; then
    read -r last_h last_t < "$sentinel" 2>/dev/null || { last_h=''; last_t=0; }
    if [ "$h" = "$last_h" ] && [ $((now - ${last_t:-0})) -lt 3600 ]; then
      exit 0   # 동일 config 에러 최근 통지됨 → 침묵
    fi
  fi
  printf '%s %s\n' "$h" "$now" > "$sentinel" 2>/dev/null || true
  FILE="$file" OUT="$out" python3 -c '
import os, json
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": "⚠ ruff config/internal error in " + os.environ["FILE"]
            + " — 이 파일의 lint이 미검증 상태입니다. ruff 설정을 확인하세요:\n" + os.environ["OUT"]
    }
}))
' 2>/dev/null
  exit 0
fi

# dedup: 위반 목록에는 dedup이 없어 무관한 기존 lint 부채가 매 Edit마다 재주입돼
# 피로·스코프크립을 유발했다. 파일별 sentinel에 이번 출력 체크섬을 저장 — 직전과 동일한 위반
# 세트면 재출력을 스킵. sentinel이 1시간(3600초) 이상 지났으면 강제로 다시 보여준다(완전 영구
# 침묵 방지). date 실패 환경에서도 타이머가 무력화되지 않도록 위 config-error dedup과 동일 패턴.
viol_dir="${TMPDIR:-/tmp}/claude-$(id -u)"
mkdir -p "$viol_dir" 2>/dev/null || true
viol_key="$(printf '%s' "$file" | cksum | tr -d ' ' | cut -d' ' -f1)"
viol_sentinel="${viol_dir}/claude-ruff-viol-${viol_key}.last"
viol_h="$(printf '%s' "$out" | cksum | tr -d ' ')"
viol_now="$(date +%s 2>/dev/null)"; : "${viol_now:=0}"
if [ -f "$viol_sentinel" ]; then
  read -r viol_last_h viol_last_t < "$viol_sentinel" 2>/dev/null || { viol_last_h=''; viol_last_t=0; }
  if [ "$viol_h" = "$viol_last_h" ] && [ $((viol_now - ${viol_last_t:-0})) -lt 3600 ]; then
    exit 0   # 동일 위반 세트 최근 통지됨 → 침묵
  fi
fi
printf '%s %s\n' "$viol_h" "$viol_now" > "$viol_sentinel" 2>/dev/null || true

# 위반이 있으면 additionalContext로 모델에 전달 (PostToolUse는 차단 불가, 피드백만)
FILE="$file" OUT="$out" python3 -c '
import os, json
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": "ruff lint issues in " + os.environ["FILE"] + ":\n"
            + os.environ["OUT"] + "\n\n계속하기 전에 이 lint 문제를 고치세요. "
            + "이번 편집에서 새로 생긴 위반이면 지금 고치고, 이미 있던 위반이면 스코프를 벗어난 것일 수 있습니다."
    }
}))
'
exit 0
