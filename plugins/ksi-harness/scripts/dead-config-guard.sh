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

# ── 전역 하네스 정합(프로젝트와 무관 · 하루 1회 throttle) ──────────────────────────────
# 왜 여기: 문서↔기계 드리프트(frontmatter가 준다고 한 model/effort와 산문의 안내가 다름, 죽은 /스킬 참조,
# memory가 사라진 절을 SSOT로 지목)는 사람이 읽어야만 보여서 감사 3회가 같은 걸 반복 발견했다. 기계로 옮기고
# 세션 시작에 밀어 올린다. 알림-only(아무것도 막지 않음) — 훅 doctrine 그대로.
cons=""
sentinel="${TMPDIR:-/tmp}/claude-ksi-consistency.last"
now="$(date +%s 2>/dev/null)"; : "${now:=0}"
skip_cons=0
if [ -f "$sentinel" ] && [ "$now" -gt 0 ]; then
  last="$(cat "$sentinel" 2>/dev/null)"; : "${last:=0}"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $((now - last)) -lt 86400 ] && skip_cons=1
fi
if [ "$skip_cons" -eq 0 ] && [ -f "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/scripts/harness-selfcheck.py" ]; then
  out="$(timeout 10 python3 "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/scripts/harness-selfcheck.py" consistency 2>/dev/null)"
  if [ $? -eq 1 ]; then
    n="$(printf '%s' "$out" | grep -c '^  ✗ ')"
    first="$(printf '%s' "$out" | grep -m1 '^  ✗ ' | sed 's/^  ✗ //')"
    cons="⚠ 하네스 정합 불일치 ${n}건 — 문서가 안내하는 값과 기계가 실제로 주는 값이 다름. 예: ${first}
(전체: \`python3 ~/.claude/scripts/harness-selfcheck.py consistency\`. 알림-only — 지금 안 고쳐도 된다.)"
  fi
  [ "$now" -gt 0 ] && printf '%s' "$now" > "$sentinel" 2>/dev/null
fi

# settings.local.json도 본다 — 같은 footgun을 넣을 수 있는데 예전엔 settings.json만 검사해서
# 로컬 오버라이드로 죽은 엔드포인트를 강제해도 통과했다.
cfg="$cwd/.claude/settings.json"
cfg_local="$cwd/.claude/settings.local.json"
if [ ! -f "$cfg" ] && [ ! -f "$cfg_local" ]; then
  [ -z "$cons" ] && exit 0
  WARN="$cons" python3 -c '
import os, json
print(json.dumps({"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":os.environ["WARN"]}}))
' 2>/dev/null
  exit 0
fi

warn="$(CFG="$cfg" CFG_LOCAL="$cfg_local" python3 -c '
import os, json
def _load(p):
    try:
        return json.load(open(p)) if p and os.path.isfile(p) else None
    except Exception:
        return None  # 파싱 불가면 그 파일은 건너뛴다(다른 도구 소관)
_main, _local = _load(os.environ["CFG"]), _load(os.environ["CFG_LOCAL"])
if _main is None and _local is None:
    raise SystemExit
# local이 main을 덮으므로 병합해서 실제로 먹는 값을 본다(env는 키 단위 병합).
# 주의: 이 python 본문은 셸의 python3 -c 작은따옴표 안에 있다 — 주석에도 작은따옴표를 쓰지 말 것.
# 쓰면 셸 문자열이 거기서 끊겨 스크립트가 잘리고, 2>/dev/null이 그 에러를 삼켜 훅이 조용히 죽는다.
d = dict(_main or {})
if _local:
    merged_env = dict((d.get("env") or {}))
    merged_env.update(_local.get("env") or {})
    d.update(_local)
    if merged_env:
        d["env"] = merged_env
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
    srcs = [n for n, v in (("settings.json", _main), ("settings.local.json", _local)) if v is not None]
    print("⚠ dead-config 경고 — 이 프로젝트 `.claude/" + "` + `".join(srcs) + "`:\n- " + "\n- ".join(issues)
          + "\n(전역 doctrine: 로컬 LLM은 하네스 용도로 쓰지 않는다. 이 설정은 세션을 깨거나 권한을 우회시킬 수 있음 — 제거를 권장.)")
' 2>/dev/null)"

[ -n "$cons" ] && warn="$(printf '%s%s%s' "$cons" "${warn:+$'\n\n'}" "$warn")"
[ -z "$warn" ] && exit 0
WARN="$warn" python3 -c '
import os, json
print(json.dumps({"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":os.environ["WARN"]}}))
' 2>/dev/null
exit 0
