---
name: goals
description: 프로젝트의 장기 목표를 세션 너머로 기억하는 durable goal-ledger. 목표를 제품/보완/결정 대기로 나눠 제품 현황을 사람 말로 낸다(`report`). "완료"는 자기신고가 아니라 증거 게이트로만 인정하고(위험 표면은 reviewer 반증 필수), 조기완료로 드러나면 무효화·재오픈한다.
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
$G report [--brief] [--ids]                    # ★ 사람용 제품 현황 — "현황/어디까지 됐나" 질문의 기본 경로
$G status [--brief]                            # 내부 상태기계 렌더(진단용) — 사용자에게 그대로 보여주지 않는다
$G register --id G001 --kind product|hardening|decision --title "..." --criteria "기준1; 기준2" [--verification light|standard|strict] [--parent ID]
                                                # --kind 필수(기본값 없음). product=사용자가 쓸 수 있게 되는 것 · hardening=감사findings·부채·검증인프라 · decision=대표자 결정 대기
                                                # --verification 미지정 시 kind 기본값(product=standard·hardening=light). 위험 키워드(권한·결제·마이그레이션·삭제·복구…) 매칭 시 지정과 무관하게 strict로 자동 승격(하향 불가)
$G start --id G001                             # proposed/blocked/in_progress→in_progress (재호출 무해)
$G block --id G001 --reason "..."              # 외부 의존 대기
$G attempt --id G001 --evidence "..."          # 완료 '시도' 기록(증거) — 아직 completed 아님
$G gate   --id G001 --verdict pass|refuted|degraded --note "..." [--reviewer NAME --evidence-ref REF]
                                                # gate는 in_progress에서만. pass엔 --evidence-ref 항상 필수, --reviewer는 strict에서만 필수(light/standard는 선택). refuted/degraded는 둘 다 선택
$G invalidate --id G001 --reason "..." --reopen "G002:제목; G003:제목"   # 조기완료 무효화
$G abandon --id G001 --reason "..."            # 되돌리기 명령 없음 — 오상취소면 register로 새 id 발급
$G set-kind --id G001 --kind product|hardening|decision [--verification light|standard|strict]
                                                # kind 재분류(마이그레이션 오분류 교정) — 모든 상태에서 허용(라벨이지 상태전이 아님). --verification은 verification_requested만 갱신, 실효값은 effective_verification()이 재계산(민감 키워드 승격은 여기서도 못 내림)
```

## ★ 증거 게이트 (우회 금지)
증거 요구는 모든 목표에 같고, **reviewer 호출 여부만 `verification` 강도로 갈린다.**

1. **증거 기록(강도 무관·항상)**: `attempt --evidence`에 구체 산출물(테스트 명령+출력 · 실제 상태전이 trace · 스크린샷 경로 · file:line). "done"·"passes"는 증거가 아니다.
2. **검증 — 강도별**:
   - **strict**(위험 표면 자동 승격 + 명시 지정): `attempt` 후 반드시 reviewer(opus·read-only)를 spawn해 등록된 `completion_criteria` 대비 그 증거가 완료를 증명하는지 **반증 시도**(인터랙티브: Task `subagent_type: reviewer` / 워크플로: `agent({agentType:'reviewer'})`). 큰 목표는 `/codebase-audit`·`/ui-audit`로 게이트. **메인이 직접 pass를 찍지 않는다 — reviewer가 깨려다 못 깨야 pass.**
   - **standard**(제품 목표 기본): 메인이 증거를 직접 대조해 pass 가능. 다만 자기가 구현한 목표를 자기가 통과시키는 자리면 reviewer를 붙인다(`CLAUDE.md` reviewer 호출 기준과 동일).
   - **light**(hardening 기본): 증거 기록 + 관련 테스트로 충분. reviewer 불필요.
3. **판정만 기록**: `gate --verdict pass --evidence-ref <아티팩트경로/transcript id>`(strict는 `--reviewer <검증주체>`도 필수)로 →completed. 픽스처 우회·self-report·green인데 안 작동이면 `gate --verdict refuted --note "..."`(→in_progress 유지, attempt++).
4. **DEGRADED**: 게이트 verify가 rate-limit으로 죽으면 pass 금지 — `gate --verdict degraded`(completed 불가·증거 클리어·재검증 강제).

**강제되는 것**: 증거 없는(공백 포함) pass 불가 · `--kind` 없는 register 불가 · 위험 키워드 매칭 시 strict 자동 승격(하향 불가) · strict의 `--reviewer` 필수 · 전이 가드(gate는 in_progress에서만, completed는 invalidate로만 탈출) · refuted/degraded는 증거를 비워 새 attempt 강제 · gate 없이 attempt 3회 초과 반복 시 `ungated_attempts` 경고(비차단 넛지).
**강제 안 되는 것**: reviewer를 실제로 spawn했는지, `--reviewer`에 진짜 검증 주체를 적었는지(헬퍼는 I/O만). 우회한 가짜 pass는 다음 세션 `invalidate`로 잡는다.

`completion_criteria`는 합의된 수용기준(brainstorming spec 또는 인라인 합의)을 그대로 쓴다(`register --criteria`). **전체 CI·전체 테스트를 여기 넣지 않는다** — goal 완료 조건이 아니라 병합·릴리즈 체크포인트의 일이다.

## 흐름
`report` 복원 → `start` → 작업 → `attempt` → (강도별 검증) → `gate pass`/refuted 반복 → 다음 목표.
**사용자가 "현황·어디까지 됐나"를 물으면 `report`다.** `status`의 내부 어휘(`proposed`·`in_progress`·`actionable`·`gate PASS`)를 그대로 옮기지 않는다 — 그건 검증 시스템의 상태지 제품의 상태가 아니다.
