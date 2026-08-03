#!/usr/bin/env bash
# 멀티머신 동기화 — repo 최신화 + 플러그인 갱신 + 훅 회귀를 한 줄로.
# 사용: scripts/sync-machine.sh [--plugin|--native]   (미지정 시 자동 감지)
#   --plugin : 플러그인 설치 머신(예: Windows git-bash). marketplace/plugin update → 훅 회귀(dist).
#   --native : ~/.claude에 골격 로컬 사본을 직접 운용하는 머신. pull로 들어온 변경의
#              패리티 확인 목록 출력 → 훅 회귀(로컬 ~/.claude/hooks 실측).
#              ⚠ 자동 복사는 하지 않는다 — 로컬 스킬은 도메인 예시를 유지하는 게 정상이라
#                기계 diff/복사는 노이즈·역행. 적용 판단은 사람/메인 에이전트가.
# 의존: bash·git (+플러그인 모드는 claude CLI). Windows는 git-bash에서 실행.
set -u
cd "$(dirname "$0")/.." || exit 2

MODE="${1:-auto}"
# 자동 감지: 이 골격의 훅 로컬 사본이 ~/.claude/hooks에 있으면 native, 아니면 plugin
if [ "$MODE" = "auto" ]; then
  if [ -f "$HOME/.claude/hooks/ui-render-check.sh" ]; then MODE=--native; else MODE=--plugin; fi
  echo "== 모드 자동 감지: $MODE =="
fi
case "$MODE" in --plugin|--native) ;; *) echo "사용법: scripts/sync-machine.sh [--plugin|--native]"; exit 2 ;; esac

echo "== 1) repo 최신화 (fetch 우선 규칙) =="
before="$(git rev-parse HEAD)"
git pull --ff-only || { echo "✘ git pull 실패 — 로컬 변경/divergence를 정리하고 재실행"; exit 1; }
after="$(git rev-parse HEAD)"
if [ "$before" != "$after" ]; then
  echo "-- 새로 들어온 커밋:"
  git log --oneline "$before..$after" | sed 's/^/   /'
else
  echo "-- 이미 최신"
fi

case "$MODE" in
  --plugin)
    echo "== 2) 플러그인 갱신 =="
    if command -v claude >/dev/null 2>&1; then
      claude plugin marketplace update ksi-tools || echo "⚠ marketplace update 실패 — Claude Code 안에서 /plugin으로 수동 갱신"
      claude plugin update ksi-harness || claude plugin update ksi-harness@ksi-tools \
        || echo "⚠ plugin update 실패 — claude plugin install ksi-harness@ksi-tools 시도"
      echo "-- 적용은 Claude Code 재시작 후."
    else
      echo "⚠ claude CLI가 PATH에 없음 — Claude Code 안에서 /plugin으로 갱신"
    fi
    echo "== 2.5) 워크플로·스크립트 배치 (플러그인 번들이 못 나르는 자산을 ~/.claude에 배치) =="
    # 플러그인 번들은 skills/agents/hooks만 자동설치하고, saved workflow(.js)·ksi-goals.py는
    # 나르지 않는다(공식 미지원 — plugins.md 구조 규약에 workflows/ 없음. ${CLAUDE_PLUGIN_ROOT}도
    # 스킬 prose에선 확장 안 됨). 스킬 본문이 참조하는 ~/.claude/{workflows,scripts} 경로를 여기서
    # 명시적으로 채워 native와 같은 경로로 수렴시킨다(이게 없으면 감사 스킬이 조용히 인터랙티브로 강등).
    mkdir -p "$HOME/.claude/workflows" "$HOME/.claude/scripts"
    if cp -f templates/workflows/*.js "$HOME/.claude/workflows/" 2>/dev/null; then
      echo "   ✓ templates/workflows/*.js → ~/.claude/workflows/ ($(ls templates/workflows/*.js 2>/dev/null | wc -l)개)"
    else
      echo "   ⚠ workflows 복사 실패 — templates/workflows/ 확인"
    fi
    for s in ksi-goals.py harness-selfcheck.py load-guard.sh capture.mjs journey.mjs; do
      cp -f "plugins/ksi-harness/scripts/$s" "$HOME/.claude/scripts/" 2>/dev/null \
        && echo "   ✓ $s → ~/.claude/scripts/" || echo "   ⚠ $s 복사 실패"
    done
    mkdir -p "$HOME/.claude/templates"
    for t in visual-qa.yml domain-invariants.example.md; do
      cp -f "templates/$t" "$HOME/.claude/templates/" 2>/dev/null \
        && echo "   ✓ $t → ~/.claude/templates/" || echo "   ⚠ $t 복사 실패"
    done
    echo "== 3) 훅 행동 회귀 (dist 스크립트, 이 머신의 bash/python3 이식성 검증) =="
    bash scripts/test-hooks.sh || exit 1
    ;;
  --native)
    echo "== 2) 패리티 확인 목록 (자동 복사 안 함) =="
    if [ "$before" != "$after" ]; then
      files="$(git diff --name-only "$before..$after" -- plugins/ksi-harness templates 2>/dev/null)"
      if [ -n "$files" ]; then
        echo "-- 새 커밋이 만진 plugin/template 파일 — 로컬 ~/.claude/{skills,agents,hooks,workflows} 대응물에 변경 의미를 반영했는지 확인:"
        printf '%s\n' "$files" | sed 's/^/   /'
      else
        echo "-- plugin/template 변경 없음(README·scripts만)"
      fi
    else
      echo "-- (새 커밋 없음)"
    fi
    echo "== 3) 훅 행동 회귀 (로컬 ~/.claude/hooks 실측) =="
    bash scripts/test-hooks.sh "$HOME/.claude/hooks" || exit 1
    ;;
esac

echo
echo "✅ sync-machine 완료 ($MODE)   (의존성 전체 점검: bash scripts/doctor.sh)"
