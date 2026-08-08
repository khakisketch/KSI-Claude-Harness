---
description: 플러그인 설치 후 1회 — 보조 스크립트를 ~/.claude/에 배치한다
---

# ksi-setup — 설치 마무리

플러그인 번들은 skills·agents·hooks를 자동 설치하지만, **보조 스크립트는 나르지 않는다**
(플러그인 구조 규약에 해당 슬롯이 없다). `goals` 스킬은 이 파일들을 `~/.claude/scripts/`
경로로 호출하므로, 설치 후 한 번 여기로 복사해 준다. 이미 있으면 최신본으로 덮어쓴다.

## 할 일

1. 플러그인 루트를 확인한다:

   ```bash
   echo "${CLAUDE_PLUGIN_ROOT:-미설정}"
   ```

   비어 있으면 이 커맨드는 플러그인 컨텍스트 밖에서 실행된 것이다 — repo를 clone해
   쓰는 native 설치라면 대신 `bash scripts/sync-machine.sh --plugin`을 쓰라고 안내하고 멈춘다.

2. 보조 스크립트를 배치한다. 목록은 `doctor.sh`가 검사하는 것과 같아야 한다:

   ```bash
   mkdir -p "$HOME/.claude/scripts"
   for s in ksi-goals.py harness-selfcheck.py; do
     cp -f "$CLAUDE_PLUGIN_ROOT/scripts/$s" "$HOME/.claude/scripts/"
   done
   ```

3. 실제로 동작하는지 확인한다 — 복사됐다는 말 대신 돌려서 확인한다:

   ```bash
   python3 "$HOME/.claude/scripts/harness-selfcheck.py" smoke 2>&1 | head -3
   bash "$CLAUDE_PLUGIN_ROOT/scripts/doctor.sh" 2>&1 | tail -8
   ```

4. 결과를 2줄 이내로 보고한다: smoke 결과 · doctor가 지적한 누락 의존성. 실패가 있으면
   무엇이 실패했는지 그대로 적는다.

## 주의

- `~/.claude/settings.json`과 `~/.claude/CLAUDE.md`는 건드리지 않는다. 훅 배선은 플러그인이 이미 갖고 있다.
- 이 커맨드는 덮어쓰기다. 사용자가 `~/.claude/scripts/`의 파일을 직접 수정해 쓰고
  있었다면 그 변경이 사라진다 — 실행 전에 해당 디렉토리에 파일이 이미 있으면 알리고
  확인을 받는다.
