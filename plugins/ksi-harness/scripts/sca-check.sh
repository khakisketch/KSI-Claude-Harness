#!/usr/bin/env bash
# PostToolUse hook: 의존성 매니페스트/lockfile을 Edit/Write 하면 SCA(pip-audit / npm audit)를 돌려
# high+ 취약점을 모델에 피드백한다(PostToolUse는 차단 불가 — 넛지만, 배포 블로커 판단은 모델/사용자).
# graceful: 도구 미설치·해당 파일 아님·파일 없음이면 통과하되, '보안 게이트 미검증'은 1줄로 가시화(은폐 금지).
# lockfile-aware: poetry.lock/pyproject.toml(poetry 프로젝트)은 `poetry export`로, Pipfile.lock은
# `pipenv requirements`로 변환한 실제 lock 내용을 pip-audit -r로 감사한다 — bare pip-audit은 훅이 도는 Python 환경의
# 설치 패키지만 보므로 lockfile의 취약 pin을 조용히 놓칠 수 있다(false green). 변환 도구가 없으면 bare로 폴백하지
# 않고 '미검증'을 명시 통지한다(은폐 금지). poetry 없는 순수 pep621 pyproject.toml은 `pip-audit <project_path>`로
# 선언된 의존성을 직접 해석해 감사한다(환경 상태에 의존하지 않음).
# dedup: 같은 파일+내용을 1시간 내 재검사하지 않는다(SCA는 느림 — 매 저장마다 PyPI 조회 방지).
# 3-게이트 doctrine: ruff/pytest가 못 잡는 차원(코드 변경 없이도 overnight CVE) — 전역 CLAUDE.md SCA 게이트의 기계화.
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"

input="$(cat)"
file="$(printf '%s' "$input" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin); ti = d.get("tool_input", {}) or {}
    print(ti.get("file_path") or ti.get("path") or "")
except Exception:
    print("")
' 2>/dev/null)"
[ -z "$file" ] && exit 0

base="$(basename "$file")"
eco=""
case "$base" in
  requirements*.txt|pyproject.toml|poetry.lock|Pipfile.lock) eco=py ;;
  package.json|package-lock.json|yarn.lock|pnpm-lock.yaml) eco=node ;;
  *) exit 0 ;;
esac

# diff-aware(0.8.3): pyproject.toml/package.json은 [tool.*]·scripts·name 등 비-의존성 편집이 대부분인데
# 그때도 매번 네트워크 SCA(≤120s)가 돌던 낭비를 교정 — Edit/MultiEdit의 changed text에 의존성 신호가 없으면 스킵.
# 신호 = dependenc 키워드 · 버전 specifier(==/>=/^N/~N/@N) · **점 버전 토큰(N.N)**. 점 버전을 포함하는 이유(자가감사 confirmed):
#   exact-pin(npm save-exact "lodash":"4.17.21" · poetry bare django="4.2.0")은 operator가 없어 이전엔 통째로 스킵됐고,
#   'lockfile 갱신이 잡는다'는 커버리지는 illusory였다(lockfile은 Bash로 재생성 → 이 PostToolUse(Edit) 훅이 발화 안 함).
#   점 버전 감지로 exact-pin을 직접 잡는다. 대가: X.Y 소수를 담은 일부 config 편집이 보수적으로 RUN(오탐<미탐 우선, 1h dedup이 반복 억제).
# requirements*.txt(0.9.10)는 TOML/JSON이 아니라 한 줄 = 한 requirement라 신호 판정이 더 단순·정확하다: 각 줄에서
# '#' 뒤 주석을 잘라내고 남는 코드(패키지명·버전·환경 마커)가 old/new 사이에 동일하면(주석/공백만 바뀜) 스킵.
# Write(전체)·lockfile(poetry.lock/Pipfile.lock)은 게이트 없이 항상 검사 — 이미 해석된 의존성 스냅샷이라 diff 판단이 무의미.
case "$base" in
  pyproject.toml|package.json)
    dep_touched="$(printf '%s' "$input" | python3 -c '
import sys, json, re
try:
    ti = (json.load(sys.stdin).get("tool_input") or {})
except Exception:
    print("1"); sys.exit(0)
old = ti.get("old_string") or ""
new = ti.get("new_string") or ""
if not (old or new):
    print("1"); sys.exit(0)
DEP = re.compile(r"dependenc|==|>=|<=|~=|!=|\^[0-9]|~[0-9]|@\^?[0-9]|[0-9]+\.[0-9]", re.I)
print("1" if (DEP.search(old) or DEP.search(new)) else "0")
' 2>/dev/null)"
    [ "${dep_touched:-1}" = "0" ] && exit 0 ;;
  requirements*.txt)
    dep_touched="$(printf '%s' "$input" | python3 -c '
import sys, json
try:
    ti = (json.load(sys.stdin).get("tool_input") or {})
except Exception:
    print("1"); sys.exit(0)
old = ti.get("old_string") or ""
new = ti.get("new_string") or ""
if not (old or new):
    print("1"); sys.exit(0)
def norm(s):
    lines = []
    for line in s.splitlines():
        code = line.split("#", 1)[0].strip()
        if code:
            lines.append(code)
    return lines
print("0" if norm(old) == norm(new) else "1")
' 2>/dev/null)"
    [ "${dep_touched:-1}" = "0" ] && exit 0 ;;
esac

[ -f "$file" ] || exit 0
dir="$(dirname "$file")"

# dedup (파일별 sentinel + 내용 해시 + 1시간 윈도우)
key="$(printf '%s' "$file" | cksum | tr -d ' ' | cut -d' ' -f1)"
sentinel="${TMPDIR:-/tmp}/claude-sca-${key}.last"
h="$(cksum < "$file" 2>/dev/null | tr -d ' ')"
now="$(date +%s 2>/dev/null)"; : "${now:=0}"
if [ -f "$sentinel" ]; then
  read -r last_h last_t < "$sentinel" 2>/dev/null || { last_h=''; last_t=0; }
  if [ "$h" = "$last_h" ] && [ $((now - ${last_t:-0})) -lt 3600 ]; then exit 0; fi
fi
printf '%s %s\n' "$h" "$now" > "$sentinel" 2>/dev/null || true

emit() { MSG="$1" python3 -c '
import os, json
print(json.dumps({"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":os.environ["MSG"]}}))
' 2>/dev/null; }

if [ "$eco" = py ]; then
  if ! command -v pip-audit >/dev/null 2>&1; then
    emit "⚠ SCA 미검증: ${base} 변경됨인데 pip-audit 미설치 — \`pip install pip-audit\` 후 점검 필요(의존성 취약점 게이트는 ruff/pytest가 못 잡는 차원)."
    exit 0
  fi

  # lockfile-aware 분기(Finding A): eco=py 트리거(requirements*.txt|pyproject.toml|poetry.lock|Pipfile.lock)를
  # 예전엔 requirements*.txt만 `pip-audit -r`로 lockfile 내용을 보고, 나머지는 bare `pip-audit`(훅이 도는 환경의 설치
  # 패키지만 감사)로 흘려 poetry/pipenv 프로젝트에서 취약 pin이 있어도 "취약점 없음"으로 조용히 통과하는 false green이 있었다.
  # pymode로 실제 감사 대상을 결정한다: poetry(export한 lock 내용) · pipenv(requirements 변환) · pep621(pip-audit의
  # project_path 해석 — 환경과 무관하게 선언된 의존성을 직접 감사) · reqfile(기존과 동일).
  case "$base" in
    poetry.lock) pymode=poetry ;;
    Pipfile.lock) pymode=pipenv ;;
    pyproject.toml)
      # `^\s*\[tool\.poetry`(prefix·선행공백 허용) — bare `[tool.poetry]` 없이 `[tool.poetry.dependencies]`만
      # 있거나 들여쓴 헤더인 poetry 프로젝트를 pep621로 오판해 poetry-only 의존성을 놓치는 edge 봉합(safe-side).
      if [ -f "$dir/poetry.lock" ] || grep -qE '^[[:space:]]*\[tool\.poetry' "$file" 2>/dev/null; then
        pymode=poetry
      else
        pymode=pep621
      fi ;;
    *) pymode=reqfile ;;
  esac

  # 하드닝: 종전 `out="$(cmd|tail)"; rc=${PIPESTATUS[0]}`는 이 스크립트의 `set -o pipefail`(라인 7)
  # 덕에 실제로는 마지막 명령의 rc를 정확히 잡고 있었다(pipefail이면 파이프라인 exit=우측 최우선 비-0 → 대입문 exit로 전파,
  # 이 전파는 poetry export/pipenv requirements를 pip-audit -r /dev/stdin으로 파이프하는 아래 분기에도 동일하게 적용된다).
  # tail 없이 rc를 먼저 잡고 자르면 pipefail 유무와 무관하게 정확하고, PIPESTATUS(bashism)도 제거돼 이식성이 오른다.
  case "$pymode" in
    poetry)
      if ! command -v poetry >/dev/null 2>&1; then
        emit "⚠ SCA 미검증: ${base}는 poetry 프로젝트로 보이는데 poetry 미설치 — lockfile 내용을 감사할 수 없습니다(환경 기준 pip-audit은 poetry.lock의 실제 pin을 보지 못해 false green 위험). \`poetry export --format=requirements.txt --without-hashes | pip-audit -r /dev/stdin\` 으로 수동 점검하세요."
        exit 0
      fi
      # stderr를 stdout과 분리 캡처(2>err) — 합치면(2>&1) poetry의 deprecation 경고 등 stderr 줄이
      # requirements 스트림에 섞여 pip-audit -r 파싱을 깨고 정상 lockfile을 '취약'으로 오분류한다(over-warn).
      errf="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/sca-poetry-err.$$")"
      exp="$(cd "$dir" && poetry export --format=requirements.txt --without-hashes 2>"$errf")"; exprc=$?
      if [ "$exprc" -ne 0 ]; then
        emit "⚠ SCA 미검증: \`poetry export\` 실패(poetry-plugin-export 미설치 등) — ${file}의 lockfile 내용을 감사하지 못했습니다:
$(cat "$errf" 2>/dev/null)

\`poetry self add poetry-plugin-export\` 후 재시도하거나 수동 점검하세요. (bare pip-audit로 조용히 대체하지 않습니다 — false green 방지.)"
        rm -f "$errf"; exit 0
      fi
      rm -f "$errf"
      out="$(printf '%s\n' "$exp" | pip-audit -r /dev/stdin 2>&1)"; rc=$? ;;
    pipenv)
      if ! command -v pipenv >/dev/null 2>&1; then
        emit "⚠ SCA 미검증: ${base} 변경됨인데 pipenv 미설치 — Pipfile.lock 내용을 감사할 수 없습니다. \`pipenv requirements | pip-audit -r /dev/stdin\` 으로 수동 점검하세요."
        exit 0
      fi
      # stderr 분리(위 poetry와 동일 이유 — pipenv의 Courtesy Notice 등이 requirements에 섞이는 것 방지).
      errf="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/sca-pipenv-err.$$")"
      exp="$(cd "$dir" && pipenv requirements 2>"$errf")"; exprc=$?
      if [ "$exprc" -ne 0 ]; then
        emit "⚠ SCA 미검증: \`pipenv requirements\` 실패 — ${file}의 lockfile 내용을 감사하지 못했습니다:
$(cat "$errf" 2>/dev/null)

수동 점검하세요. (bare pip-audit로 조용히 대체하지 않습니다 — false green 방지.)"
        rm -f "$errf"; exit 0
      fi
      rm -f "$errf"
      out="$(printf '%s\n' "$exp" | pip-audit -r /dev/stdin 2>&1)"; rc=$? ;;
    pep621)
      out="$(pip-audit "$dir" 2>&1)"; rc=$? ;;
    reqfile)
      out="$(cd "$dir" && pip-audit -r "$base" 2>&1)"; rc=$? ;;
  esac
  out="$(printf '%s\n' "$out" | tail -n 40)"
elif [ "$eco" = node ]; then
  if ! command -v npm >/dev/null 2>&1; then
    emit "⚠ SCA 미검증: ${base} 변경됨인데 npm 미설치 — \`npm audit --audit-level=high\` 점검 필요."
    exit 0
  fi
  out="$(cd "$dir" && npm audit --audit-level=high 2>&1)"; rc=$?
  out="$(printf '%s\n' "$out" | tail -n 40)"
fi

[ "${rc:-0}" -eq 0 ] && exit 0   # 취약점 없음(또는 high 미만)

# 도구 자체 오류(네트워크 단절·resolution 실패 등)는 취약점 발견이 아니다 — 오프라인마다 거짓 배포 블로커로
# 오표기되는 것을 막는다. 좁은 마커셋만 걸러 진짜 advisory까지 "도구 오류"로 강등시키지 않는다.
if printf '%s' "$out" | grep -qiE 'ERROR:pip|npm error|audit endpoint returned an error|ECONNREFUSED|ENOTFOUND|ETIMEDOUT|EAI_AGAIN|No matching distribution|Failed to (install|resolve|fetch)|Temporary failure in name resolution'; then
  emit "⚠ SCA 미검증(도구 오류 — 취약점 아님) — ${file}:
${out}

pip-audit/npm audit 실행 자체가 실패했습니다(네트워크 단절·resolution 오류 등) — 취약점이 발견된 게 아니므로 배포 블로커가 아닙니다. 온라인 상태에서 재점검하세요."
  exit 0
fi

emit "⚠ SCA(의존성 취약점) — ${file}:
${out}

high+ 미해결은 배포 블로커로 취급하세요(전역 doctrine). 해결 불가면 사유와 잔여 리스크를 명시."
exit 0
