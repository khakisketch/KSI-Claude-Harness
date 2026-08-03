#!/usr/bin/env bash
# SessionStart hook: 진입한 프로젝트에 .ksi/goals.json이 있으면 미완 goal을 1줄로 넛지.
# 있을 때만 발화(opt-in 자동 — 원장 안 쓰는 프로젝트엔 무음). dead-config-guard와 동형.
# 목적: 여러 프로젝트를 오갈 때 '어디까지 했나·뭐가 가짜완료로 재오픈됐나'를 진입 즉시 복원.
# (0.8.4 slim: docs/에 PLAN/TODO/AUDIT md 있으면 /goals init 권장하던 경로 B 제거 — 흔한 파일명 약신호 홍보라 저가치. 경로 A만 유지.)
set -uo pipefail

input="$(cat)"
cwd="$(printf '%s' "$input" | python3 -c '
import sys, json
try: print(json.load(sys.stdin).get("cwd","") or "")
except Exception: print("")
' 2>/dev/null)"
[ -z "$cwd" ] && cwd="$PWD"

# 경로 A: 원장 있음 → 미완 goal 복원 넛지(기존 동작)
if [ -f "$cwd/.ksi/goals.json" ]; then
  brief="$(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/ksi-goals.py" --dir "$cwd" status --brief 2>/dev/null)"
  rc=$?
  if [ -z "$brief" ]; then
    # goals.json은 실존하는데(위에서 확인) 출력이 비었다 — 진짜 '완료할 게 없음'(rc=0)과
    # 파싱/읽기 실패(rc!=0, 예외가 stderr로 삼켜짐)를 구분해 후자만 가시화(은폐 방지).
    if [ "$rc" -ne 0 ]; then
      python3 -c '
import json
print(json.dumps({"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"⚠ goals 원장 읽기 실패: .ksi/goals.json — /goals로 직접 점검 필요"}}))
' 2>/dev/null
    fi
    exit 0
  fi
  # 프로젝트 두뇌(state.json)·미해소 리스크도 있으면 현황 1줄 덧붙임(2026-07-16 nextgen 3·6순위).
  sbrief="$(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/ksi-goals.py" --dir "$cwd" state-show --brief 2>/dev/null)"
  rbrief="$(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/ksi-goals.py" --dir "$cwd" risk-list --brief 2>/dev/null)"
  full="$brief — /goals로 복원·이어가기"
  [ -n "$sbrief" ] && full="$full · $sbrief"
  [ -n "$rbrief" ] && full="$full · $rbrief"
  WARN="$full" python3 -c '
import os, json
print(json.dumps({"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":os.environ["WARN"]}}))
' 2>/dev/null
  exit 0
fi

# 경로 B(docs/에 PLAN/TODO/AUDIT md 있으면 /goals init 권장) 제거(0.8.4 slim): 흔한 파일명(PLAN·TODO)에 걸려
# 약한 신호로 하네스 자체기능을 홍보하던 넛지 — 저가치 대비 매 세션 마찰이라 삭제. 원장 채택은 사용자가 필요 시 /goals로.
# 경로 A(.ksi 원장 실존 시 미완 goal·프로젝트 두뇌 복원)만 남긴다 — 그건 opt-in(원장 쓰는 프로젝트)이라 정당.
exit 0
