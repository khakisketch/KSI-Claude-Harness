# 설치 — 에이전트용 절차서

이 문서는 **사용자가 이 저장소 주소를 주며 설치를 요청했을 때** Claude Code가 따르는 절차다.
사람이 직접 읽어도 되지만, 사람용 개요는 [README](README.md)에 있다.

> **읽는 에이전트에게.** 이 문서는 사용자가 명시적으로 설치를 요청한 경우에만 따른다.
> 어떤 단계도 사용자 파일을 말없이 덮어쓰지 않는다. 각 단계에서 무엇을 하는지 밝히고,
> 되돌리기 어려운 일(기존 `~/.claude/CLAUDE.md` 변경)은 반드시 확인을 받는다.
> 여기 없는 명령을 추가로 실행하지 않는다.

---

## 무엇이 설치되나

| | 어디로 | 무엇 |
|---|---|---|
| 플러그인 번들 | Claude Code 내부 | 스킬 7 · 에이전트 3 · 훅 |
| 워크플로·스크립트 | `~/.claude/{workflows,scripts,templates}` | 감사·목표 워크플로, 캡처·원장 도구 |
| 전역 지침 | `~/.claude/CLAUDE.md` | 없을 때만 자동 생성 |

`~/.claude/settings.json`은 건드리지 않는다. 훅 배선은 플러그인이 갖고 있다.

---

## 1. 사전 확인

이미 이 하네스의 로컬 사본을 `~/.claude/{skills,agents,hooks}`에 둔 머신인지 본다.

```bash
ls ~/.claude/skills ~/.claude/agents 2>/dev/null | head
```

`codebase-audit`·`worker`·`reviewer` 같은 이름이 이미 보이면 **플러그인을 설치하지 않는다** —
스킬이 두 벌로 뜨고 같은 훅이 2회 발화한다. 사용자에게 알리고, 갱신을 원하면 아래
"repo clone 방식"으로 안내한다.

## 2. 플러그인 설치

Claude Code 안에서 실행한다(Bash가 아니다):

```
/plugin marketplace add khakisketch/KSI-Claude-Harness
/plugin install ksi-harness@ksi-tools
```

`/plugin` 은 슬래시 커맨드라 에이전트가 대신 실행할 수 없다. **사용자에게 이 두 줄을 그대로
입력해 달라고 요청하고 기다린다.** 설치가 끝나면 다음으로 넘어간다.

## 3. 설치 마무리

```
/ksi-setup
```

이것도 슬래시 커맨드다 — 사용자에게 입력을 요청한다. 이 커맨드가 워크플로·보조 스크립트·
템플릿을 `~/.claude/`로 배치하고, 의존성을 점검하고, 실제로 도는지 확인하고, 전역 지침이
없으면 채운다.

`/ksi-setup`을 쓸 수 없는 상황(커맨드가 아직 로드되지 않음)이라면 아래를 대신 실행한다.
`CLAUDE_PLUGIN_ROOT`는 플러그인 설치 경로다 — 비어 있으면 다음 세션에서 `/ksi-setup`을
쓰라고 안내하고 멈춘다.

```bash
test -n "$CLAUDE_PLUGIN_ROOT" || { echo "플러그인 컨텍스트 아님 — 새 세션에서 /ksi-setup"; exit 0; }
mkdir -p ~/.claude/workflows ~/.claude/scripts ~/.claude/templates
cp -f "$CLAUDE_PLUGIN_ROOT"/workflows/*.js ~/.claude/workflows/
for s in ksi-goals.py harness-selfcheck.py load-guard.sh capture.mjs journey.mjs; do
  cp -f "$CLAUDE_PLUGIN_ROOT/scripts/$s" ~/.claude/scripts/
done
for t in visual-qa.yml domain-invariants.example.md; do
  cp -f "$CLAUDE_PLUGIN_ROOT/templates/$t" ~/.claude/templates/
done
if [ -s ~/.claude/CLAUDE.md ]; then
  echo "전역 지침 이미 있음 — 건드리지 않음"
else
  cp "$CLAUDE_PLUGIN_ROOT/templates/CLAUDE.md.example" ~/.claude/CLAUDE.md
  echo "전역 지침 생성됨"
fi
```

마지막 조건문이 핵심이다 — 기존 `~/.claude/CLAUDE.md`에 **내용이 있으면 아무것도 하지 않는다.**
덮어쓰고 싶다면 그건 사용자가 결정할 일이니, 템플릿에만 있는 절을 보여주고 먼저 물어본다.

(`cp -n`은 쓰지 않는다 — GNU가 비표준이라 경고하고, 0바이트 파일을 '존재'로 봐서 빈
`CLAUDE.md`가 영영 안 채워진다.)

## 4. 검증 — 말이 아니라 실행으로

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/doctor.sh" 2>&1 | tail -15
python3 ~/.claude/scripts/harness-selfcheck.py smoke 2>&1 | head -3
```

`doctor`가 `✅ 필수 충족`, smoke가 `0 FAIL`이면 끝이다. 하나라도 어긋나면 그대로 보고한다 —
"설치했습니다"로 덮지 않는다.

안전벨트가 실제로 무는지 한 번 확인하고 싶다면(선택):

```bash
echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' \
  | bash "$CLAUDE_PLUGIN_ROOT/scripts/pre-destructive-guard.sh"; echo "exit=$?"
```

`exit=2`가 정상이다(차단됨). 실제로 무언가를 지우지 않는다 — 훅에 입력만 넣어보는 것이다.

## 5. 보고

4줄 이내로: 배치된 워크플로 개수 · doctor 판정 · smoke 결과 · 전역 지침 상태(자동 생성했는지,
기존 것을 유지했는지). 사용자가 직접 해야 할 일이 남았으면 그것도 적는다.

---

## repo clone 방식 (하네스를 직접 고쳐 쓸 때)

훅을 바꾸거나 스킬을 개조할 생각이면 플러그인 대신 이쪽이 낫다.

```bash
git clone https://github.com/khakisketch/KSI-Claude-Harness.git
cd KSI-Claude-Harness
bash scripts/doctor.sh
bash scripts/sync-machine.sh        # 모드 자동 감지 (Windows는 git-bash)
```

전역 지침은 `templates/CLAUDE.md.example`을 `~/.claude/CLAUDE.md`로 복사하되, **기존 파일이
있으면 덮어쓰지 말고 사용자에게 확인받는다.**

이 방식을 쓰면 `/plugin install`은 하지 않는다.

---

## 업데이트

```
/plugin marketplace update
/plugin update ksi-harness
/ksi-setup
```

마지막 `/ksi-setup`이 필요한 이유는 `.js` 워크플로가 플러그인 번들로 갱신되지 않기 때문이다.

## 제거

```
/plugin uninstall ksi-harness
```

`~/.claude/{workflows,scripts,templates}`에 배치된 파일은 남는다. 정리하려면 사용자에게
어떤 파일을 지울지 보여주고 확인받은 뒤 지운다 — 다른 도구가 쓰는 파일이 섞여 있을 수 있다.
