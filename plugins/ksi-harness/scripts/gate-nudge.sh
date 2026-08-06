#!/usr/bin/env bash
# UserPromptSubmit hook: 착수 게이트 넛지 — 새 기능/새 프로젝트/대형 리팩터 어휘가 잡히면
# 구현 전 목표/범위/비범위/수용기준 선작성을 1줄로 상기. 세션당 1회, 비차단(goal-status와 동형).
# 근거: 하네스 감사 — 착수 게이트가 forcing function 부재로 저사용(모델 self-select 한계).
#       goals가 SessionStart 훅으로 저사용을 탈출한 패턴의 UserPromptSubmit판. 오탐 억제가 우선(보수적 어휘).
# 자가감사(GATE-1~3 cluster) 수정: (a) 계측 우선 — 매칭 발화 자체를 세션과 별개인
#   durable 로그에 남겨 "안 뜬다" vs "떴는데 무시된다"를 다음 감사에서 구분 가능하게 함(실측 발화 횟수가
#   너무 작아 원인 특정 불가였음). (b) escape clause 삭제 — "이미 spec이 합의된
#   작업이면 무시하고 진행"이 스스로 skip 명분을 쥐여줬음. (c) 요구를 "스킬 호출"에서 "목표/범위/비범위/
#   수용기준 3~5줄 선작성"으로 하향 — inline으로 충족 가능해 순응률 개선 기대(실측 AskUserQuestion 사용
#   패턴과 정렬). (d) 안전한 어휘만 확장(scaffold, 새/신규+시스템·플로우·플랫폼·모듈) — "명사+추가/넣/붙이
#   인접" 등 넓은 확장은 소작업(예: "API에 파라미터 추가해줘")에서 높은 FP로 실측 기각.
set -uo pipefail

input="$(cat)"
out="$(GATE_INPUT="$input" python3 - <<'PY' 2>/dev/null
import json, os, re, sys, time, tempfile

try:
    d = json.loads(os.environ.get("GATE_INPUT", "") or "{}")
except Exception:
    sys.exit(0)

# Windows 이식성: os.getuid()는 POSIX 전용 — Windows Python에선 AttributeError로 훅이 죽어(넛지 무발화)
# /tmp도 C:\tmp로 오해석. gettempdir()+getuid 폴백으로 통일(POSIX 동작 불변).
def _tmpbase():
    return os.path.join(tempfile.gettempdir(), f"claude-{getattr(os, 'getuid', lambda: 0)()}")
prompt = d.get("prompt", "") or ""
sid = d.get("session_id", "") or "nosession"
# 슬래시 커맨드·짧은 프롬프트·이미 게이트를 언급한 프롬프트엔 침묵
if prompt.startswith("/") or len(prompt) < 8:
    sys.exit(0)
if re.search(r"brainstorming|착수\s?게이트", prompt):
    sys.exit(0)
# 보수적 착수 어휘 — 스코프 명사(기능·프로젝트·화면…)와의 결합을 요구한다.
# 단독 build-동사('구현해줘'·'만들어줘')는 함수 구현·테스트 작성 같은 소작업에서 오탐이라 매칭하지 않는다
# (reviewer 반증으로 협소화 — 길이 게이트도 그때 완화: 짧은 정당 트리거 미탐 해소).
# scaffold·"새/신규+시스템·플로우·플랫폼·모듈"만 안전 확장 추가(FP 없는 kickoff 한정어 동반).
# slim: 한정어 없는 `기능 추가/붙이/넣` 브랜치 제거 — "정렬 기능 추가해줘"·"로깅 기능 넣어줘" 같은
#   소작업에 오발하던 주범(over-restriction 감사). 새/신규 기능·대형 리팩터·build-verb 브랜치가 진짜 kickoff는 이미 잡는다.
PAT = re.compile(
    r"(새\s?(기능|프로젝트|화면|페이지|서비스|앱|모듈|시스템|플로우|플랫폼)"
    r"|신규\s?(기능|프로젝트|서비스|화면|시스템|플로우|플랫폼|모듈)"
    r"|(대형|대규모|전면)\s?(리팩터|리팩토링|개편|재설계)"
    r"|처음부터|밑바닥부터|from scratch|greenfield|scaffold"
    r"|(기능|프로젝트|화면|페이지|서비스|앱)[^\n]{0,6}(만들|구현|개발)(어|해|하)?\s?(줘|주세요|보자|하자|시작))"
)
# 계측: 매칭 여부와 무관하게 durable 로그에 남기지 않는다(모든 프롬프트를 남기면 로그가 프롬프트 전문을
# 담아 민감정보 위험) — 매칭된 것만, 세션당 1회 dedup 이전 시점에 남겨 "발화 시도" 자체를 durable하게 센다.
if PAT.search(prompt):
    try:
        logdir = _tmpbase()
        os.makedirs(logdir, exist_ok=True)
        with open(os.path.join(logdir, "gate-nudge-fires.log"), "a") as lf:
            lf.write(f"{int(time.time())}\t{sid}\n")
    except Exception:
        pass
if not PAT.search(prompt):
    sys.exit(0)
# 세션당 1회 dedup (sentinel) — 넛지 자체(사용자에게 보이는 신호)는 여전히 세션 1회로 제한(피로 방지).
# 위 로그는 이 dedup 이전에 이미 기록되므로 "실제 매칭 횟수"와 "발화 횟수"를 분리해서 잴 수 있다.
sent = os.path.join(_tmpbase(), f"gate-nudge-{sid}")
try:
    os.makedirs(os.path.dirname(sent), exist_ok=True)
    if os.path.exists(sent):
        sys.exit(0)
    open(sent, "w").close()
except Exception:
    pass
msg = (
    "(훅, 세션 1회) 새 기능·대형 리팩터로 보입니다 — 목표/범위/비범위/수용기준을 3~5줄로 먼저 적으면 재작업이 줍니다. "
    "이미 범위가 합의됐거나 소규모면 그대로 진행하세요. 해석이 갈리면 /brainstorming."
)
print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": msg}}, ensure_ascii=False))
PY
)"
[ -n "${out:-}" ] && printf '%s\n' "$out"
exit 0
