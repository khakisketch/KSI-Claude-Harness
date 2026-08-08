#!/usr/bin/env bash
# PreToolUse(Bash) hook: 파괴적 명령 하드가드 — permissions.deny의 프리픽스 패턴("Bash(rm -rf:*)")이
# 못 막는 변형(rm -fr·/bin/rm·command rm·플래그 분리)과 force-push·인터랙티브 DROP DATABASE를 차단(exit 2).
# 원칙: 표적은 '복구 불가급'만(루트/홈/시스템 최상위/보호 디렉토리) — 스크래치·node_modules류 rm -rf는
#       통과시켜 자율성을 보존한다. 오차단이 의심되면 ksi_safety.py의 규칙을 좁혀라(넓히기보다 좁히기 우선).
# 근거: 하네스 감사 — 공식 docs가 Bash 인자 제약 deny를 "fragile"로 명시, PreToolUse가 권고 방어선.
# 실제 로직은 ksi_safety.py(run_destructive) — 여기는 launcher일 뿐이다(2026-08-08 shell heredoc 제거).
set -uo pipefail
exec python3 "$(dirname -- "$0")/ksi_safety.py" destructive
