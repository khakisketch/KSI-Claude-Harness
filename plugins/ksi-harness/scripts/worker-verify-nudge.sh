#!/usr/bin/env bash
# SubagentStop hook (matcher: worker): worker 서브에이전트가 끝나면 "산출물을 self-report로 신뢰하지
# 말고 실제 근거로 재검증하라"를 1줄 상기시킨다(방법(reviewer 스폰)을 못박지 않고 결과(재검증)를 요구 —
# 소규모는 메인 인라인 재검증도 producer≠verifier라 유효, 크거나 위험하면 reviewer 격리). 비차단(additionalContext만) —
# 사소한 worker 위임(트리거 어휘 붙이기 등)까지 매번 막으면 gate-nudge가 겪은 피로·crying-wolf를 재현한다.
# 근거: 하네스 자가감사 — SubagentStop 훅 이벤트가 worker→reviewer 핸드오프를 구조적으로
#       넛지할 수 있는데 미배선이었음(audit-loop.js 같은 워크플로 경로는 verify가 이미 코드에 baked-in되지만,
#       인터랙티브 Agent 스폰 경로는 넛지가 전무했다).
set -uo pipefail

input="$(cat)"
out="$(HOOK_INPUT="$input" python3 - <<'PY' 2>/dev/null
import json, os, sys, tempfile

try:
    d = json.loads(os.environ.get("HOOK_INPUT", "") or "{}")
except Exception:
    sys.exit(0)

agent_type = d.get("agent_type", "") or ""
if agent_type != "worker":
    sys.exit(0)

# dedup (자가감사 critic 적발): 이 훅 자신이 신설 당일 'Stop 훅 dedup 부재'와 같은 결함을 갖고
# 있었다 — worker fan-out 세션에서 worker가 끝날 때마다 같은 문단이 재주입됨. 넛지는 세션당 1회면 충분
# (일반 원칙 리마인더라 fileset 키가 없음 — gate-nudge와 동형의 세션 sentinel).
sid = d.get("session_id", "") or "nosession"
# Windows 이식성: os.getuid() POSIX 전용·/tmp→C:\tmp 오해석 → gettempdir()+getuid 폴백(POSIX 불변).
sent = os.path.join(tempfile.gettempdir(), f"claude-{getattr(os, 'getuid', lambda: 0)()}", f"workernudge-{sid}")
try:
    os.makedirs(os.path.dirname(sent), exist_ok=True)
    if os.path.exists(sent):
        sys.exit(0)
    open(sent, "w").close()
except Exception:
    pass

msg = (
    "worker 산출물입니다(SubagentStop 넛지, 비차단): 코드 변경이 있었다면 완료로 간주하기 전 "
    "self-report(\"완료/테스트통과\")를 그대로 믿지 말고 **실제 근거로 재검증**하세요 — 변경 diff를 직접 재확인하고 "
    "해당 테스트를 재실행. 변경이 크거나 위험 표면(auth·자금·상태전이·마이그레이션)을 건드렸거나 context 격리가 "
    "필요하면 reviewer로 분리 검증하세요."
)
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SubagentStop", "additionalContext": msg}}, ensure_ascii=False))
PY
)"
[ -n "${out:-}" ] && printf '%s\n' "$out"
exit 0
