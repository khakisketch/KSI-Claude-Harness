---
name: goals
description: 프로젝트의 장기 목표를 세션 너머로 기억하는 durable goal-ledger. "완료"는 자기신고가 아니라 adversarial 증거 게이트(reviewer 검증)로만 인정하고, 조기완료로 드러나면 무효화·재오픈한다.
when_to_use: 프로젝트급·멀티세션·substantive 목표를 추적할 때(예 — "이 제품을 파일럿 납품 수준까지"). 여러 프로젝트를 오갈 때 "어디까지 했나·뭐가 가짜로 끝났나"를 복원. **단일 편집·오타·1세션·단순 CRUD엔 쓰지 말 것**(발동은 명시적, trivial은 원장을 안 건드린다).
---

# Goals — durable goal-ledger

프로젝트별 `.ksi/{goals.json(상태), ledger.jsonl(append-only 이벤트)}`. 상태 I/O는 결정론적 헬퍼가, 완료 판정은 adversarial 증거 게이트가 한다.

## 상태기계
`proposed → in_progress ⇄ blocked → (게이트 pass) completed → (무효화) false_positive_complete → 재오픈` · `proposed/in_progress/blocked → abandoned`(completed·false_positive_complete는 invalidate로만 탈출, abandon 불가)

## 헬퍼 (직접 JSON 손편집 금지)
```bash
G="python3 ~/.claude/scripts/ksi-goals.py"   # CWD의 .ksi/ 대상
$G init [--project NAME]                       # .ksi/ 생성(git 커밋 — gitignore 금지)
$G status [--brief]                            # 현황(브리프=넛지 1줄)
$G register --id G001 --title "..." --criteria "기준1; 기준2; 기준3" [--parent ID]
$G start --id G001                             # proposed/blocked/in_progress→in_progress (재호출 무해)
$G block --id G001 --reason "..."              # 외부 의존 대기
$G attempt --id G001 --evidence "..."          # 완료 '시도' 기록(증거) — 아직 completed 아님
$G gate   --id G001 --verdict pass|refuted|degraded --note "..." [--reviewer NAME --evidence-ref REF]
                                                # gate는 in_progress에서만. pass엔 --reviewer·--evidence-ref 필수(누락 시 에러), refuted/degraded는 선택
$G invalidate --id G001 --reason "..." --reopen "G002:제목; G003:제목"   # 조기완료 무효화
$G abandon --id G001 --reason "..."            # 되돌리기 명령 없음 — 오상취소면 register로 새 id 발급
```

## ★ 증거 게이트 (우회 금지)
목표를 완료하려 할 때:
1. **증거 기록**: `attempt --evidence`에 구체 산출물(테스트 명령+출력 · 실제 상태전이 trace · 스크린샷 경로 · file:line). "done"·"passes"는 증거가 아니다.
2. **reviewer로 adversarial 검증**: `attempt` 후 반드시 reviewer(opus·xhigh·read-only)를 spawn해, 등록된 `completion_criteria` 대비 그 증거가 실제로 완료를 증명하는지 반증 시도(인터랙티브: Task `subagent_type: reviewer` / 워크플로: `agent({agentType:'reviewer'})`). 큰 목표는 `/codebase-audit`·`/ui-audit`로 게이트.
3. **판정만 기록**: reviewer가 확인하면 `gate --verdict pass --reviewer <검증주체> --evidence-ref <아티팩트경로/transcript id>`(→completed), 픽스처 우회·self-report·green인데 안 작동이면 `gate --verdict refuted --note "..."`(→in_progress 유지, attempt++). **메인이 직접 pass를 찍지 않는다 — reviewer가 깨려다 못 깨야 pass.**
4. **DEGRADED**: 게이트 verify가 rate-limit으로 죽으면 pass 금지 — `gate --verdict degraded`(completed 불가·증거 클리어·재검증 강제).

**강제되는 것**: 증거 없는(공백 포함) pass 불가 · 전이 가드(gate는 in_progress에서만, completed는 invalidate로만 탈출) · refuted/degraded는 증거를 비워 새 attempt 강제 · gate 없이 attempt 3회 초과 반복 시 `ungated_attempts` 경고(비차단 넛지).
**강제 안 되는 것**: reviewer를 실제로 spawn했는지, `--reviewer`에 진짜 검증 주체를 적었는지(헬퍼는 I/O만). 우회한 가짜 pass는 다음 세션 `invalidate`로 잡는다.

`completion_criteria`는 deep-interview 합의 spec의 수용기준을 그대로 쓴다(`register --criteria`).

## 흐름
`status` 복원 → `start` → 작업 → `attempt` → reviewer 게이트 → `gate pass`/refuted 반복 → 다음 목표.

## `/goals run` — 자율 실행 (evidence-gated)
실물화: `~/.claude/workflows/goals-run.js`(native는 saved workflow로 자동등록 · 플러그인 머신은 `/ksi-setup`이 `~/.claude/workflows/`에 배치).
`args: {dir(프로젝트 경로, 필수), maxGoals(세션 예산, 기본 6·천장 20), context}`.
동작 계약(종료조건·red-lane·evidence-gate·세션-경계 stitching)은 `goals-run.js` 상단 RUN CONTRACT 주석이 SSOT.
