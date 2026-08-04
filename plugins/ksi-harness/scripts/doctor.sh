#!/usr/bin/env bash
# 의존성 doctor — 하네스가 활용하는 도구를 점검하고 OS별 설치 힌트를 출력한다.
# 자동 설치는 하지 않는다: 패키지 매니저·권한(sudo)이 머신마다 달라 침습적이고,
# "위험한 건 수동" 원칙과 일치 — 정확한 설치 명령 힌트까지만.
# 특히 ruff는 없으면 lint 훅이 '조용히' skip되므로(README 경고), 여기서 가시화한다.
# 사용: scripts/doctor.sh   (exit 0=필수 충족, 1=필수 누락)
set -u

OS="$(uname -s 2>/dev/null || echo unknown)"
case "$OS" in
  Linux*)              OS_NAME="Linux";   PM="sudo apt install" ;;
  Darwin*)             OS_NAME="macOS";   PM="brew install" ;;
  MINGW*|MSYS*|CYGWIN*) OS_NAME="Windows(git-bash)"; PM="winget install" ;;
  *)                   OS_NAME="$OS";     PM="(패키지 매니저)" ;;
esac
echo "== 하네스 의존성 doctor — $OS_NAME =="
echo

miss_req=0
chk() { # chk <필수|권장|정보> <명령> <용도> <설치 힌트>
  local lvl="$1" cmd="$2" use="$3" hint="$4"
  if command -v "$cmd" >/dev/null 2>&1; then
    printf '  ✓ %-9s %s\n' "$cmd" "$use"
  else
    case "$lvl" in
      필수) printf '  ✘ %-9s %s\n      → %s\n' "$cmd" "$use (필수 — 없으면 훅/동기화 불능)" "$hint"; miss_req=1 ;;
      권장) printf '  ⚠ %-9s %s\n      → %s\n' "$cmd" "$use" "$hint" ;;
      정보) printf '  · %-9s %s\n      → %s\n' "$cmd" "$use" "$hint" ;;
    esac
  fi
}

echo "-- 필수 (훅·동기화의 최소 실행 환경)"
chk 필수 git     "훅의 미커밋 교차·sync-machine·플러그인 설치" "$PM git  (Windows: Git for Windows = git-bash 포함, git-scm.com/download/win)"
chk 필수 python3 "세 훅 전부의 JSON 파싱" "$PM python3  (Windows: python.org 설치 후 git-bash PATH 확인)"
chk 필수 claude  "Claude Code CLI — 플러그인 설치/갱신" "docs.anthropic.com/claude-code 설치 안내"
echo
echo "-- 권장 (없으면 해당 기능이 '조용히' 빠짐)"
chk 권장 ruff    "lint 훅 — 없으면 .py 저장 시 점검이 silent skip" "pipx install ruff  또는  pip install --user ruff  (PATH에 ~/.local/bin)"
chk 권장 pip-audit "SCA 훅 — 없으면 requirements/lock 변경 시 의존성 취약점 점검이 '미검증'으로 표기됨" "pipx install pip-audit  또는  pip install --user pip-audit"
chk 권장 node    "ui-audit 캡처(Playwright 실행 기반) — UI 캡처 안 하는 머신엔 불필요" "$PM nodejs  (또는 nvm)"
if command -v npx >/dev/null 2>&1 && npx --no-install playwright --version >/dev/null 2>&1; then
  printf '  ✓ %-9s %s\n' playwright "ui-audit 스크린샷 캡처"
else
  printf '  ⚠ %-9s %s\n      → %s\n' playwright "ui-audit 캡처 — UI 캡처하는 머신만 필요(또는 playwright-mcp 대안)" \
    "프로젝트에서: npm i -D playwright && npx playwright install chromium"
fi
echo
echo "-- 정보 (역할에 따라)"
chk 정보 gh      "repo publish/PR — 메인테이너만" "$PM gh  (cli.github.com)"
echo
# 배치 안내는 설치 형태에 따라 다르다 — 플러그인만 설치한 머신엔 repo의 scripts/가 없어서
# sync-machine.sh를 안내하면 막다른 길이 된다.
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] || [ ! -f scripts/sync-machine.sh ]; then
  FIXHINT="/ksi-setup  (워크플로·스크립트·템플릿을 ~/.claude로 배치)"
else
  FIXHINT="bash scripts/sync-machine.sh --plugin  (스크립트·워크플로·템플릿 재배치)"
fi
echo "-- 워크플로 배치 (감사 스킬이 Workflow로 호출하는 saved workflow)"
if [ -f "$HOME/.claude/workflows/audit-loop.js" ]; then
  printf '  ✓ %-9s %s\n' workflows "~/.claude/workflows/ 배치됨 (감사 스킬이 canonical 경로로 호출)"
else
  printf '  ⚠ %-9s %s\n      → %s\n' workflows \
    "~/.claude/workflows/ 미배치 — 감사 스킬이 인터랙티브 fallback으로 강등됨" \
    "$FIXHINT"
fi
if [ -f "$HOME/.claude/scripts/load-guard.sh" ] && [ -f "$HOME/.claude/scripts/capture.mjs" ] \
   && [ -f "$HOME/.claude/scripts/journey.mjs" ] && [ -f "$HOME/.claude/templates/visual-qa.yml" ] \
   && [ -f "$HOME/.claude/templates/domain-invariants.example.md" ]; then
  printf '  ✓ %-9s %s\n' scripts "~/.claude/{scripts,templates} 배치됨 (load-guard·capture·journey·visual-qa·domain-invariants — ui-audit §2/§3-B 라우팅)"
else
  printf '  ⚠ %-9s %s\n      → %s\n' scripts \
    "load-guard.sh/capture.mjs/journey.mjs/visual-qa.yml/domain-invariants.example.md 미배치 — ui-audit §2/§3-B 라우팅 미동작(구버전 배치 상태)" \
    "$FIXHINT"
fi
echo
echo "-- 프로젝트별 (하네스 전역 아님 — 각 프로젝트 CLAUDE.md 완료 게이트 소관)"
echo "  · mypy/pytest(Python) · tsc/typecheck(TS) — 프로젝트 가상환경/devDependencies로."
echo "-- MCP: 하네스 하드 의존 없음 — playwright-mcp는 ui-audit 캡처의 '옵션' 대안일 뿐."
echo

if [ "$miss_req" -eq 1 ]; then
  echo "✘ 필수 누락 있음 — 위 힌트로 설치 후 재실행 (자동 설치는 의도적으로 안 함)"
  exit 1
fi
echo "✅ 필수 충족 — 권장 항목은 머신 역할에 맞게 선택"
