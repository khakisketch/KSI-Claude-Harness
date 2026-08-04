---
description: 플러그인 설치 후 1회 — 감사·목표 워크플로와 보조 스크립트를 ~/.claude/에 배치한다
---

# ksi-setup — 설치 마무리

플러그인 번들은 skills·agents·hooks를 자동 설치하지만, **saved workflow(`.js`)와 보조
스크립트는 나르지 않는다**(플러그인 구조 규약에 해당 슬롯이 없다). `codebase-audit`·
`ui-audit`·`goals` 스킬은 이 파일들을 `~/.claude/` 경로로 호출하므로, 설치 후 한 번
여기로 복사해 준다. 이미 있으면 최신본으로 덮어쓴다.

## 할 일

1. 플러그인 루트를 확인한다:

   ```bash
   echo "${CLAUDE_PLUGIN_ROOT:-미설정}"
   ```

   비어 있으면 이 커맨드는 플러그인 컨텍스트 밖에서 실행된 것이다 — repo를 clone해
   쓰는 native 설치라면 대신 `bash scripts/sync-machine.sh --plugin`을 쓰라고 안내하고 멈춘다.

2. 워크플로·보조 스크립트·템플릿을 배치한다. 목록은 `doctor.sh`가 검사하는 것과 같아야 한다
   — 하나라도 빠지면 `ui-audit`의 캡처 라우팅이 조용히 강등된다:

   ```bash
   mkdir -p "$HOME/.claude/workflows" "$HOME/.claude/scripts" "$HOME/.claude/templates"
   cp -f "$CLAUDE_PLUGIN_ROOT"/workflows/*.js "$HOME/.claude/workflows/"
   for s in ksi-goals.py harness-selfcheck.py load-guard.sh capture.mjs journey.mjs; do
     cp -f "$CLAUDE_PLUGIN_ROOT/scripts/$s" "$HOME/.claude/scripts/"
   done
   for t in visual-qa.yml domain-invariants.example.md; do
     cp -f "$CLAUDE_PLUGIN_ROOT/templates/$t" "$HOME/.claude/templates/"
   done
   ```

3. 실제로 동작하는지 확인한다 — 복사됐다는 말 대신 돌려서 확인한다:

   ```bash
   ls -1 "$HOME/.claude/workflows/"*.js
   python3 "$HOME/.claude/scripts/harness-selfcheck.py" smoke 2>&1 | head -3
   bash "$CLAUDE_PLUGIN_ROOT/scripts/doctor.sh" 2>&1 | tail -12
   ```

4. **전역 지침(`~/.claude/CLAUDE.md`)** — 플러그인은 전역 지침을 심을 수 없어 여기서 채운다.
   있고 없고에 따라 다르게 처리한다. 아래를 그대로 실행하면 분기가 결정된다:

   ```bash
   if [ -s "$HOME/.claude/CLAUDE.md" ]; then echo "EXISTS"; else echo "ABSENT"; fi
   ```

   - **`ABSENT`** — 자동으로 채운다. 잃을 게 없다:

     ```bash
     mkdir -p "$HOME/.claude"
     if [ -s "$HOME/.claude/CLAUDE.md" ]; then
       echo "이미 내용 있음 — 건드리지 않음"
     else
       cp "$CLAUDE_PLUGIN_ROOT/templates/CLAUDE.md.example" "$HOME/.claude/CLAUDE.md"
       echo "생성됨 ($(wc -l < "$HOME/.claude/CLAUDE.md")줄)"
     fi
     ```

     복사했다고 보고하고, **스택 섹션(Python/TS/DB 등)은 팀에 맞게 고치라**고 1줄 덧붙인다.

   - **`EXISTS`** — **덮어쓰지 않는다.** 사용자가 쌓아온 지침을 말없이 날리는 건 되돌릴 수
     없다. 대신 템플릿에만 있는 내용을 보여주고, 병합할지 물어본다:

     ```bash
     diff --unified=0 "$HOME/.claude/CLAUDE.md" \
       "$CLAUDE_PLUGIN_ROOT/templates/CLAUDE.md.example" | head -40
     ```

     차이가 크면 전문을 붙여넣지 말고 "템플릿에만 있는 절: A·B·C" 수준으로 요약해 제시한다.
     사용자가 병합을 원하면 해당 절만 덧붙이고, 기존 문장은 건드리지 않는다.

   판정(`-s`)과 복사를 같은 조건문에 묶는다. `cp -n`은 쓰지 않는다 — GNU가 "동작이 바뀔 수
   있다"고 경고하는 비표준 플래그인 데다, **0바이트 파일을 '존재'로 봐서** 판정은 `ABSENT`인데
   복사는 건너뛰는 어긋남이 생긴다(빈 `CLAUDE.md`가 영영 안 채워진다).

5. 결과를 4줄 이내로 보고한다: 배치된 워크플로 개수 · smoke 결과 · doctor가 지적한 누락
   의존성 · 전역 지침 상태(자동 생성/기존 유지). 실패가 있으면 무엇이 실패했는지 그대로 적는다.

## 주의

- `~/.claude/settings.json`은 건드리지 않는다. 훅 배선은 플러그인이 이미 갖고 있다.
- 이 커맨드는 덮어쓰기다. 사용자가 `~/.claude/workflows/`의 파일을 직접 수정해 쓰고
  있었다면 그 변경이 사라진다 — 실행 전에 해당 디렉토리에 파일이 이미 있으면 알리고
  확인을 받는다.
