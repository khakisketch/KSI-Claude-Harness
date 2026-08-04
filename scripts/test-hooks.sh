#!/usr/bin/env bash
# 검증 게이트 훅 4종 + SessionStart 업데이트 알림 훅의 행동 회귀 테스트 — 합성 git repo + 합성 transcript로 발화/침묵을 검사한다.
# 훅 수정 후, 그리고 새 머신(Linux·macOS·Windows git-bash)에서 한 번 돌려 이식성을 확인한다.
# 사용: scripts/test-hooks.sh [hooks-dir]   (기본: <repo>/plugins/ksi-harness/scripts)
# 의존: bash·git·python3 (훅 자체와 동일). ruff는 없으면 해당 케이스 SKIP.
set -u

HOOKS="${1:-$(cd "$(dirname "$0")/.." && pwd)/plugins/ksi-harness/scripts}"
[ -f "$HOOKS/ui-render-check.sh" ] || { echo "hooks-dir 불일치: $HOOKS"; exit 2; }

fail=0
pass() { echo "PASS  $1"; }
failt() { echo "FAIL  $1"; fail=1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
# Windows 이식성: 훅의 python은 native Windows 인터프리터라 JSON stdin으로 넘어온 MSYS 경로
# (/tmp/tmp.XXX)를 os.path로 해석 못 해 파일을 못 찾고 조용히 통과했다(테스트만의 거짓실패 — 실훅은 native 경로를 받음).
# JSON에 박는 경로만 native(cygpath -m = forward-slash, JSON 이스케이프 불필요 + Windows python 해석 가능)로 변환하고,
# bash 파일 조작은 계속 $T(MSYS)를 쓴다. POSIX(cygpath 부재)에선 TW=T로 무변화.
if command -v cygpath >/dev/null 2>&1; then TW="$(cygpath -m "$T")"; else TW="$T"; fi
SID="test-$$"   # 세션 sentinel 누적으로 인한 하드캡 flakiness 방지(고유 세션키 → 매 실행 격리)
(
  cd "$T" && git init -q . && git config user.email t@t && git config user.name t &&
  echo base > base.txt && git add . && git commit -qm base
) || { echo "테스트 repo 생성 실패"; exit 2; }
mkdir -p "$T/components" "$T/tests"
printf 'export default function D(){return null}\n' > "$T/components/D.tsx"
printf 'def test_x():\n    assert True\n' > "$T/tests/test_x.py"
printf 'def helper():\n    pass\n' > "$T/util.py"

TP="$T/transcript.jsonl"     # bash 쓰기 대상(MSYS)
TPW="$TW/transcript.jsonl"   # JSON 임베드용(native)
rec() { printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"%s"}}]}}\n' "$1"; }
pay() { printf '{"transcript_path":"%s","cwd":"%s","session_id":"%s"}' "$TPW" "$TW" "$SID"; }

run_hook() { pay | bash "$HOOKS/$1"; }
expect_block() {
  out="$(run_hook "$1")"
  case "$out" in *'"decision"'*'"block"'*) pass "$1 — $2" ;; *) failt "$1 — $2 (출력: ${out:0:60})" ;; esac
}
# Stop 훅 완료게이트는 비차단 알림(systemMessage)이다 — 발화하되 완료를 막지 않는다.
# "block 안 함"까지 함께 단언해 차단 회귀를 잡는다.
expect_notice() {
  out="$(run_hook "$1")"
  case "$out" in
    *'"decision"'*) failt "$1 — $2 (완료를 차단함: ${out:0:60})" ;;
    *'"systemMessage"'*) pass "$1 — $2" ;;
    *) failt "$1 — $2 (미발화: ${out:0:60})" ;;
  esac
}
expect_silent() {
  out="$(run_hook "$1")"
  [ -z "$out" ] && pass "$1 — $2" || failt "$1 — $2 (발화함)"
}

echo "== Stop 훅: 발화 케이스 (미커밋 변경) =="
rec "$TW/components/D.tsx" > "$TP";  expect_notice ui-render-check.sh      "미커밋 .tsx → 비차단 알림"
rec "$TW/tests/test_x.py" > "$TP";   expect_notice backend-verify-check.sh "미커밋 tests/*.py → 비차단 알림"

echo "== Stop 훅: 침묵 케이스 =="
rec "$TW/util.py" > "$TP";           expect_silent backend-verify-check.sh "순수 util.py → silent(경로 필터)"
rec "$TW/util.py" > "$TP";           expect_silent ui-render-check.sh      ".py는 프론트 훅 무관 → silent"
( cd "$T" && git add -A && git commit -qm all )
# 커밋됨 케이스는 새 세션키로 격리 — 앞 block 케이스가 남긴 dedup sentinel이 동일 fileset이라
# git-교차(커밋 제외) 회귀를 '침묵'으로 가려 false PASS 낼 수 있다(reviewer 지적). 새 SID면 침묵의 원인이 오직 git-교차.
SID="$SID-committed"
rec "$TW/components/D.tsx" > "$TP";  expect_silent ui-render-check.sh      "커밋됨 → silent(git 교차)"
rec "$TW/tests/test_x.py" > "$TP";   expect_silent backend-verify-check.sh "커밋됨 → silent(git 교차)"

echo "== Stop 훅: 루프 방지 + graceful =="
for h in ui-render-check.sh backend-verify-check.sh; do
  out="$(printf '{"stop_hook_active":true,"transcript_path":"%s","cwd":"%s"}' "$TPW" "$TW" | bash "$HOOKS/$h")"
  [ -z "$out" ] && pass "$h — stop_hook_active 통과" || failt "$h — stop_hook_active에서 발화"
  out="$(printf '{}' | bash "$HOOKS/$h")"
  [ -z "$out" ] && pass "$h — 빈 입력 graceful" || failt "$h — 빈 입력에서 발화"
done

echo "== PostToolUse 훅: ruff =="
if command -v ruff >/dev/null 2>&1; then
  printf 'import os\n' > "$T/bad.py"   # F401 unused import
  out="$(printf '{"tool_input":{"file_path":"%s"}}' "$TW/bad.py" | bash "$HOOKS/ruff-check.sh")"
  case "$out" in *additionalContext*) pass "ruff-check.sh — 위반 → 피드백 주입" ;; *) failt "ruff-check.sh — 위반인데 침묵" ;; esac
  printf 'x = 1\n' > "$T/good.py"
  out="$(printf '{"tool_input":{"file_path":"%s"}}' "$TW/good.py" | bash "$HOOKS/ruff-check.sh")"
  [ -z "$out" ] && pass "ruff-check.sh — 클린 → silent" || failt "ruff-check.sh — 클린인데 발화"
else
  echo "SKIP  ruff 미설치 — ruff 케이스 건너뜀(훅 자체는 graceful skip이 정상 동작)"
fi

echo "== PostToolUse 훅: secret-scan =="
rm -f "${TMPDIR:-/tmp}/claude-secret-scan.last"   # dedup sentinel 초기화(테스트 격리)
# 시크릿 리터럴은 런타임 생성 — 테스트 소스에 비밀 패턴을 박지 않는다.
AWSKEY="AKIA$(tr -dc 'A-Z0-9' </dev/urandom 2>/dev/null | head -c 16)"
ss() { printf '{"tool_input":{"file_path":"%s"}}' "$1" | bash "$HOOKS/secret-scan.sh"; }
printf 'KEY = "%s"\n' "$AWSKEY" > "$T/leak.py"
case "$(ss "$TW/leak.py")" in *additionalContext*) pass "secret-scan.sh — 하드코딩 키 → 경고" ;; *) failt "secret-scan.sh — 키인데 침묵" ;; esac
printf 'x = 1\n' > "$T/noleak.py"
out="$(ss "$TW/noleak.py")"; [ -z "$out" ] && pass "secret-scan.sh — 클린 → silent" || failt "secret-scan.sh — 클린인데 발화"
printf 'AWS_KEY=%s\n' "$AWSKEY" > "$T/.env.example"
out="$(ss "$TW/.env.example")"; [ -z "$out" ] && pass "secret-scan.sh — .env.example 제외 → silent" || failt "secret-scan.sh — 예시인데 발화"
mkdir -p "$T/db/migrations"; printf 'DROP TABLE users;\n' > "$T/db/migrations/001.sql"
case "$(ss "$TW/db/migrations/001.sql")" in *additionalContext*) pass "secret-scan.sh — 파괴적 DDL → 경고" ;; *) failt "secret-scan.sh — DDL인데 침묵" ;; esac

echo "== SessionStart 훅: update-check =="
UCSENT="${TMPDIR:-/tmp}/claude-ksi-update-check.last"
UCSRC="$T/ucsrc"; mkdir -p "$UCSRC/.claude-plugin"
( cd "$UCSRC" && git init -q . && git config user.email t@t && git config user.name t \
  && echo '{"name":"ksi-harness","version":"0.0.0"}' > .claude-plugin/plugin.json \
  && git add -A && git commit -qm r && git tag v0.0.5 && git tag v0.2.0 ) >/dev/null 2>&1
git clone -q "$UCSRC" "$T/ucroot" >/dev/null 2>&1
ucver() { printf '{"name":"ksi-harness","version":"%s"}\n' "$1" > "$T/ucroot/.claude-plugin/plugin.json"; }
ucrun() { rm -f "$UCSENT"; CLAUDE_PLUGIN_ROOT="$T/ucroot" bash "$HOOKS/update-check.sh" 2>/dev/null; }
if [ -f "$T/ucroot/.claude-plugin/plugin.json" ]; then
  # 주의: json.dumps가 한글을 \uXXXX로 이스케이프하므로 raw 한글이 아니라 ASCII 키(systemMessage)로 매칭한다.
  # 신선 clone 직후 첫 ls-remote가 Windows에서 4s timeout을 드물게 초과(타이밍 flake, 실측) — 1회 재시도
  ucver 0.1.0; ucout="$(ucrun)"; case "$ucout" in *systemMessage*) ;; *) ucout="$(ucrun)" ;; esac
  case "$ucout" in *systemMessage*) pass "update-check.sh — 뒤처짐 → 알림" ;; *) failt "update-check.sh — 뒤처짐인데 침묵" ;; esac
  ucver 0.2.0; out="$(ucrun)"; [ -z "$out" ] && pass "update-check.sh — 동일 → silent" || failt "update-check.sh — 동일인데 발화"
  ucver "shaXYZ"; out="$(ucrun)"; [ -z "$out" ] && pass "update-check.sh — 비-semver → silent" || failt "update-check.sh — 비-semver인데 발화"
  git -C "$T/ucroot" remote set-url origin /nonexistent.git 2>/dev/null; ucver 0.1.0
  out="$(ucrun)"; [ -z "$out" ] && pass "update-check.sh — 원격 불가 → graceful silent" || failt "update-check.sh — 오프라인인데 발화"
  rm -f "$UCSENT"
else
  echo "SKIP  update-check (git clone 실패 — 환경)"
fi

echo "== PostToolUse 훅: sca-check =="
scaclean() { rm -f "${TMPDIR:-/tmp}"/claude-sca-*.last; }   # 파일별 dedup sentinel 초기화
sca() { printf '{"tool_input":{"file_path":"%s"}}' "$1" | bash "$HOOKS/sca-check.sh"; }
scaclean; printf 'x = 1\n' > "$T/notdep.py"
out="$(sca "$TW/notdep.py")"; [ -z "$out" ] && pass "sca-check.sh — 비-의존성 파일 → silent" || failt "sca-check.sh — 비-의존성인데 발화"
scaclean; printf 'requests==2.0.0\n' > "$T/requirements.txt"
if command -v pip-audit >/dev/null 2>&1; then
  echo "INFO  pip-audit 설치됨 — requirements 케이스는 취약점 DB 의존이라 발화/침묵 모두 정상(스킵)"
else
  case "$(sca "$TW/requirements.txt")" in *additionalContext*) pass "sca-check.sh — pip-audit 미설치 → '미검증' 발화" ;; *) failt "sca-check.sh — 미설치인데 침묵(미검증 미표기)" ;; esac
fi
scaclean

echo "== SessionStart 훅: dead-config-guard =="
dcg() { printf '{"cwd":"%s"}' "$1" | bash "$HOOKS/dead-config-guard.sh"; }
mkdir -p "$T/dcg-clean"
out="$(dcg "$TW/dcg-clean")"; [ -z "$out" ] && pass "dead-config-guard.sh — settings 없음 → silent" || failt "dead-config-guard.sh — 설정없는데 발화"
mkdir -p "$T/dcg-bad/.claude"
printf '{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:11434"},"permissions":{"defaultMode":"bypassPermissions"}}' > "$T/dcg-bad/.claude/settings.json"
case "$(dcg "$TW/dcg-bad")" in *additionalContext*) pass "dead-config-guard.sh — footgun 설정 → 경고" ;; *) failt "dead-config-guard.sh — footgun인데 침묵" ;; esac
mkdir -p "$T/dcg-ok/.claude"
printf '{"effortLevel":"high"}' > "$T/dcg-ok/.claude/settings.json"
out="$(dcg "$TW/dcg-ok")"; [ -z "$out" ] && pass "dead-config-guard.sh — 정상 설정 → silent" || failt "dead-config-guard.sh — 정상인데 발화"

echo "== SessionStart 훅: goal-status (goal-ledger 넛지) =="
PR="$(dirname "$HOOKS")"   # plugin root → CLAUDE_PLUGIN_ROOT (scripts/ksi-goals.py 위치)
gs() { printf '{"cwd":"%s"}' "$1" | CLAUDE_PLUGIN_ROOT="$PR" bash "$HOOKS/goal-status.sh"; }
mkdir -p "$T/gs-none"
out="$(gs "$TW/gs-none")"; [ -z "$out" ] && pass "goal-status.sh — .ksi 없음 → silent" || failt "goal-status.sh — 원장없는데 발화"
KG="$PR/scripts/ksi-goals.py"   # 플러그인=plugins/ksi-harness/scripts·native=~/.claude/scripts 둘 다 정확(이전 $HOOKS 가정은 native에서 false-fail)
python3 "$KG" --dir "$TW/gs-ok" init --project demo >/dev/null 2>&1
python3 "$KG" --dir "$TW/gs-ok" register --id G1 --title work >/dev/null 2>&1
python3 "$KG" --dir "$TW/gs-ok" start --id G1 >/dev/null 2>&1
case "$(gs "$TW/gs-ok")" in *additionalContext*) pass "goal-status.sh — 미완 goal → 넛지" ;; *) failt "goal-status.sh — 미완 goal인데 침묵" ;; esac

echo "== 강도 스위치 제거: KSI_HOOKS 는 더 이상 아무 것도 바꾸지 않는다 =="
# 실사용 0회로 확인돼 제거했다(bashrc·settings·프로젝트·히스토리 어디에도 설정된 적 없음).
# 차단하는 훅이 사라진 뒤로는 "관문 해제"라는 용도 자체가 없어졌고, 남은 건 짧은 알림뿐이라 끌 이유가 없다.
# 회귀 가드: 옛 값이 환경에 남아 있어도 동작이 갈리지 않아야 한다(조용한 침묵 = 최악의 실패 모드).
payid() { printf '{"transcript_path":"%s","cwd":"%s","session_id":"%s"}' "$TPW" "$TW" "$1"; }
printf 'export default function D(){return <span className="c">changed</span>}\n' > "$T/components/D.tsx"
rec "$TW/components/D.tsx" > "$TP"
# 세션키에 $$ 포함 — sentinel이 실행 간 누적돼 dedup으로 거짓침묵나는 것 방지(hermetic).
for m in "" strict warn off; do
  out="$(payid "sw-${m:-unset}-$$" | env ${m:+KSI_HOOKS=$m} bash "$HOOKS/ui-render-check.sh")"
  case "$out" in
    *'"decision"'*) failt "스위치제거 ui-render(KSI_HOOKS=${m:-unset}) — 완료를 차단함" ;;
    *'"systemMessage"'*) pass "스위치제거 ui-render(KSI_HOOKS=${m:-unset}) — 값과 무관하게 비차단 알림" ;;
    *) failt "스위치제거 ui-render(KSI_HOOKS=${m:-unset}) — 침묵(옛 스위치가 아직 살아있다)" ;;
  esac
done
out="$(printf '{"prompt":"새 기능 만들어줘 대시보드 화면","session_id":"eg-off-'"$$"'"}' | KSI_HOOKS=off bash "$HOOKS/gate-nudge.sh")"
case "$out" in *additionalContext*) pass "스위치제거 gate-nudge — off 값이어도 발화" ;; *) failt "스위치제거 gate-nudge — off에서 여전히 침묵" ;; esac
[ -e "$HOOKS/ksi-mode.sh" ] && failt "ksi-mode.sh 가 남아있다(스위치 잔재)" || pass "ksi-mode.sh 제거됨"

echo "== 안전벨트: 되돌리기-불가는 환경과 무관하게 항상 차단 =="
pdg() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")"; }
pdg "rm -rf /" | KSI_HOOKS=off bash "$HOOKS/pre-destructive-guard.sh" >/dev/null 2>&1; [ $? -eq 2 ] && pass "pre-destructive — rm -rf / → block(안전벨트)" || failt "rm -rf / 통과(안전벨트 해제!)"
pdg "git push --force origin main" | KSI_HOOKS=off bash "$HOOKS/pre-destructive-guard.sh" >/dev/null 2>&1; [ $? -eq 2 ] && pass "pre-destructive — push --force → block" || failt "push --force 통과"
pdg "git push -fu origin feature" | KSI_HOOKS=off bash "$HOOKS/pre-destructive-guard.sh" >/dev/null 2>&1; [ $? -eq 2 ] && pass "pre-destructive — push -fu(스택 플래그) → block(자가감사 봉합)" || failt "push -fu 우회(안전벨트 구멍!)"
pdg "git push -uf origin feature" | bash "$HOOKS/pre-destructive-guard.sh" >/dev/null 2>&1; [ $? -eq 2 ] && pass "pre-destructive — push -uf → block" || failt "push -uf 우회"
pdg "git push --force-with-lease origin main" | bash "$HOOKS/pre-destructive-guard.sh" >/dev/null 2>&1; [ $? -eq 0 ] && pass "pre-destructive — push --force-with-lease 단독 → allow(안전 변형)" || failt "force-with-lease 오차단"
# reset --hard·clean -f: 예전엔 warn 에서 경고로 낮췄으나 스위치 제거와 함께 차단으로 통일.
# 미커밋 작업은 git 에도 checkpoint/rewind 에도 없어 사실상 되돌리기-불가다.
pdg "git reset --hard" | bash "$HOOKS/pre-destructive-guard.sh" >/dev/null 2>&1; [ $? -eq 2 ] && pass "pre-destructive — reset --hard → block(미커밋 소실)" || failt "reset --hard 미차단"
pdg "git reset --hard" | KSI_HOOKS=warn bash "$HOOKS/pre-destructive-guard.sh" >/dev/null 2>&1; [ $? -eq 2 ] && pass "pre-destructive — reset --hard → warn 값이어도 block" || failt "reset --hard 가 옛 스위치로 우회됨"

echo "== SCA diff-aware =="
scaclean; mkdir -p "$T/scad"; printf '[tool.ruff]\nline-length = 100\n' > "$T/scad/pyproject.toml"
out="$(printf '{"tool_input":{"file_path":"%s","old_string":"line-length = 88","new_string":"line-length = 100"}}' "$TW/scad/pyproject.toml" | bash "$HOOKS/sca-check.sh" 2>&1)"
[ -z "$out" ] && pass "sca — pyproject 비-의존성 편집(tool.ruff) → skip" || failt "sca — 비-의존성인데 실행: ${out:0:40}"
# dep 신호 감지 로직을 직접 검증(네트워크 audit 없이 결정론적) — 특히 exact-pin false-negative 봉합(자가감사 confirmed)
detect() { python3 -c '
import sys, re
DEP = re.compile(r"dependenc|==|>=|<=|~=|!=|\^[0-9]|~[0-9]|@\^?[0-9]|[0-9]+\.[0-9]", re.I)
print("1" if DEP.search(sys.argv[1]) else "0")
' "$1"; }
[ "$(detect 'requests>=2.0')" = "1" ] && pass "sca dep-detect — operator dep 감지" || failt "sca — operator dep 미감지"
[ "$(detect 'lodash 4.17.21')" = "1" ] && pass "sca dep-detect — exact npm pin(N.N.N) 감지(false-neg 봉합)" || failt "sca — exact npm pin 미감지(false-negative!)"
[ "$(detect 'django = 4.2.0')" = "1" ] && pass "sca dep-detect — exact poetry pin 감지" || failt "sca — poetry exact 미감지(false-negative!)"
[ "$(detect 'line-length = 100')" = "0" ] && pass "sca dep-detect — 정수 config(tool.ruff) → 여전히 skip" || failt "sca — 정수 config 오탐"
[ "$(detect 'name = mypackage')" = "0" ] && pass "sca dep-detect — 비버전 편집 → skip" || failt "sca — 비버전 오탐"

echo "== secret-scan CREATE TABLE NOT NULL 오표기 교정 =="
rm -f "${TMPDIR:-/tmp}/claude-secret-scan.last" "${TEMP:-/tmp}/claude-secret-scan.last" 2>/dev/null   # ${TEMP:-} — set -u에서 TEMP 미설정(비-Windows) 시 unbound 방지
mkdir -p "$T/mig/migrations"
printf 'CREATE TABLE users (id INT NOT NULL, name TEXT NOT NULL);\n' > "$T/mig/migrations/001c.sql"
case "$(printf '{"tool_input":{"file_path":"%s"}}' "$TW/mig/migrations/001c.sql" | bash "$HOOKS/secret-scan.sh" 2>&1)" in
  *"NOT NULL"*) failt "secret-scan — CREATE TABLE NOT NULL을 파괴적으로 오표기" ;;
  *) pass "secret-scan — CREATE TABLE NOT NULL → 파괴적 미표기(교정)" ;;
esac
printf 'ALTER TABLE users ALTER COLUMN age SET NOT NULL;\n' > "$T/mig/migrations/002a.sql"
case "$(printf '{"tool_input":{"file_path":"%s"}}' "$TW/mig/migrations/002a.sql" | bash "$HOOKS/secret-scan.sh" 2>&1)" in
  *additionalContext*) pass "secret-scan — ALTER SET NOT NULL → 여전히 경고" ;;
  *) failt "secret-scan — ALTER SET NOT NULL인데 미발화" ;;
esac

echo "== dead-config: bypassPermissions 단독은 더는 발화 안 함 =="
mkdir -p "$T/dcg-bypass/.claude"
printf '{"permissions":{"defaultMode":"bypassPermissions"}}' > "$T/dcg-bypass/.claude/settings.json"
out="$(dcg "$TW/dcg-bypass")"; [ -z "$out" ] && pass "dead-config — bypassPermissions 단독 → silent(사용자 선호 존중)" || failt "dead-config — bypass 단독인데 발화"

echo "== gate-nudge slim: 한정어 없는 소작업 미발화 =="
gn() { printf '{"prompt":"%s","session_id":"%s"}' "$1" "$2" | bash "$HOOKS/gate-nudge.sh"; }
out="$(gn "정렬 기능 추가해줘" "gn1-$$")"; [ -z "$out" ] && pass "gate-nudge — 정렬 기능 추가(소작업) → 미발화(slim)" || failt "gate-nudge — 소작업 오발"
out="$(gn "로깅 기능 넣어줘" "gn2-$$")"; [ -z "$out" ] && pass "gate-nudge — 로깅 기능 넣어줘 → 미발화" || failt "gate-nudge — 소작업 오발2"
case "$(gn "새 기능 만들어줘 대시보드 화면" "gn3-$$")" in *additionalContext*) pass "gate-nudge — 새 기능 만들어줘 → 여전히 발화" ;; *) failt "gate-nudge — 진짜 kickoff 미발화(과협소)" ;; esac
case "$(gn "대형 리팩터 하자" "gn4-$$")" in *additionalContext*) pass "gate-nudge — 대형 리팩터 → 여전히 발화" ;; *) failt "gate-nudge — 대형 리팩터 미발화" ;; esac

echo "== goal-status slim: Path B(docs 넛지) 제거 확인 =="
gsb() { printf '{"cwd":"%s"}' "$1" | CLAUDE_PLUGIN_ROOT="$PR" bash "$HOOKS/goal-status.sh"; }
mkdir -p "$T/gsb/docs"; printf '# roadmap\n' > "$T/gsb/docs/ROADMAP.md"; printf '# todo\n' > "$T/gsb/docs/TODO.md"
out="$(gsb "$TW/gsb")"; [ -z "$out" ] && pass "goal-status — docs/에 ROADMAP·TODO 있어도 .ksi 없으면 silent(Path B 제거)" || failt "goal-status — Path B 여전히 발화"

echo "== 훅이 python3 에 실제로 넘기는 코드가 컴파일되는가 (조용한 죽음 방지) =="
# 실측 사고: secret-scan.sh 주석에 아포스트로피가 들어가 `python3 -c '...'` 셸 문자열이
# 조기 종료됐다. bash -n 은 통과하고, stderr 는 2>/dev/null 에 먹히고, 훅은 exit 0 으로 조용히 침묵 —
# 하드코딩 시크릿·파괴적 DDL 경고가 몇 주간 죽어 있었는데 아무 신호도 없었다.
# 여기서는 python3 를 shim 으로 가로채 '셸이 실제로 넘긴 코드'를 받아 py_compile 한다.
PYSHIM="$(mktemp -d)"; PYDUMP="$(mktemp -d)"
cat > "$PYSHIM/python3" <<'SHIM'
#!/usr/bin/env bash
if [ "${1:-}" = "-c" ]; then printf '%s' "$2" > "$PYDUMP_DIR/$$-$RANDOM.py"; exit 0; fi
exec "$REAL_PYTHON3" "$@"
SHIM
chmod +x "$PYSHIM/python3"
REALPY="$(command -v python3)"
for hf in "$HOOKS"/*.sh; do
  grep -q "python3 -c '" "$hf" 2>/dev/null || continue
  rm -rf "${PYDUMP:?}"/*;
  printf '{"tool_name":"Write","tool_input":{"file_path":"/tmp/zz.py"},"prompt":"x","cwd":"/tmp","session_id":"pyshim","transcript_path":"/tmp/none"}' \
    | PYDUMP_DIR="$PYDUMP" REAL_PYTHON3="$REALPY" PATH="$PYSHIM:$PATH" bash "$hf" >/dev/null 2>&1
  bad=0; cnt=0
  for pf in "$PYDUMP"/*.py; do
    [ -e "$pf" ] || continue; cnt=$((cnt+1))
    "$REALPY" -m py_compile "$pf" 2>/dev/null || bad=$((bad+1))
  done
  # cnt=0 은 조기 exit(설계상 skip)이라 정상 — 도달한 페이로드만 판정한다.
  if [ "$bad" -eq 0 ]; then pass "py-payload — $(basename "$hf") → 컴파일 가능(${cnt}개)"
  else failt "py-payload — $(basename "$hf") → 셸 인용 깨짐으로 python 코드 손상(${bad}/${cnt})"; fi
done
rm -rf "$PYSHIM" "$PYDUMP"

echo
[ $fail -eq 0 ] && echo "✅ 전체 통과" || echo "❌ 실패 있음"
exit $fail
