#!/usr/bin/env bash
# PreToolUse(Bash) hook: outbound exfiltration 넛지 + git push 시크릿 하드게이트 — pre-destructive-guard.sh가
# '삭제·되돌리기 불가'만 보고 secret/env/파일을 외부로 유출하는 패턴은 안 본다는 갭을 메운다.
# 경고(유출 의심 패턴)는 exit 0 · git push 시크릿은 하드블록(exit 2, fail-closed). 탐지 대상 상세는
# ksi_safety.py(run_egress) 상단 주석 참조. 실제 로직은 ksi_safety.py — 여기는 launcher일 뿐이다
# (2026-08-08 shell heredoc 제거).
set -uo pipefail
exec python3 "$(dirname -- "$0")/ksi_safety.py" egress
