#!/usr/bin/env bash
# SessionStart hook: 진입한 프로젝트의 .claude/settings.json이 'active footgun'을 강제하는지 1줄 경고.
# 점검: 죽은 ANTHROPIC_BASE_URL(ollama/localhost:11434 — 로컬 LLM 미사용 SSOT 위반), 강제 bypassPermissions,
# 로컬 모델 매핑 잔존. 경고만(자동수정 없음 — 레포의 update-check 훅과 동형, 우리가 안 쓰던 SessionStart 이벤트).
# 근거: 메타감사가 어느 프로젝트의 .claude/settings.json을 'Claude를 죽은 ollama:11434로 강제 + bypass'로 적발(active footgun).
set -uo pipefail

input="$(cat)"
cwd="$(printf '%s' "$input" | python3 -c '
import sys, json
try: print(json.load(sys.stdin).get("cwd","") or "")
except Exception: print("")
' 2>/dev/null)"
[ -z "$cwd" ] && cwd="$PWD"
cfg="$cwd/.claude/settings.json"
[ -f "$cfg" ] || exit 0

warn="$(CFG="$cfg" python3 -c '
import os, json
try:
    d = json.load(open(os.environ["CFG"]))
except Exception:
    raise SystemExit  # 파싱 불가면 침묵(다른 도구 소관)
issues = []
env = d.get("env") or {}
base = str(env.get("ANTHROPIC_BASE_URL", "") or "")
low = base.lower()
if base and ("11434" in base or "ollama" in low or "localhost" in low or "127.0.0.1" in base):
    issues.append("ANTHROPIC_BASE_URL=%s → 죽은 로컬 LLM 엔드포인트로 강제(로컬 LLM 미사용 SSOT 위반 — Claude 호출이 실패하거나 엉뚱한 곳으로 감)" % base)
# bypassPermissions 경고 제거: 이건 dead-config가 아니라 신뢰 환경에서의 의도적 정책 선택(원격제어·프롬프트 회피 등
# 정당한 유스케이스). 매 세션 제거-권장으로 사용자의 문서화된 선호를 반박하던 과잉 넛지를 삭제 — 이 훅은 깨진/죽은 설정만 본다.
models = []
for v in (env.get("ANTHROPIC_MODEL", ""), env.get("ANTHROPIC_SMALL_FAST_MODEL", ""), d.get("model", "")):
    s = str(v or "").lower()
    if s and any(t in s for t in ("ollama", "qwen", "nemotron", "llama", "gemma", "mistral", "/local")):
        models.append(str(v))
if models:
    issues.append("로컬 모델 매핑 잔존: %s" % ", ".join(models))
if issues:
    print("⚠ dead-config 경고 — 이 프로젝트 `.claude/settings.json`:\n- " + "\n- ".join(issues)
          + "\n(전역 doctrine: 로컬 LLM은 하네스 용도로 쓰지 않는다. 이 설정은 세션을 깨거나 권한을 우회시킬 수 있음 — 제거를 권장.)")
' 2>/dev/null)"

[ -z "$warn" ] && exit 0
WARN="$warn" python3 -c '
import os, json
print(json.dumps({"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":os.environ["WARN"]}}))
' 2>/dev/null
exit 0
