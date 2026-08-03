---
name: codebase-audit
description: 코드베이스/모듈을 여러 에이전트로 병렬 감사·분석하고, 발견을 adversarial하게 검증한 뒤 우선순위 findings로 종합한다. ui-audit의 백엔드·일반 코드 대응물 — "픽셀" 대신 코드·설정·문서를 본다. 병렬 감사가 실익일 때 그 골격을 매번 0에서 재조립하지 않기 위한 재사용 스캐폴딩.
when_to_use: substantive한 코드 감사·병렬 분석이 필요할 때 — 여러 모듈/레포 동시 점검, 리팩터/마이그레이션 전 현황 파악, 버그·취약점·일관성·완성도 sweep. 단일 파일 1~2개 조회는 쓰지 말 것(오버킬).
---

# Codebase Audit — 병렬 감사 → adversarial 검증 → 종합

## 0. 스코프 dial (먼저)
- 작은 substantive: 워커 1개 + 검증 1패스.
- 중간: 모듈 N개 = 워커 N개, adversarial 1패스.
- 큰 감사: fan-out + adversarial(새 finding 마를 때까지, maxRounds dial — 기본값 SSOT=audit-loop.js LOOP CONTRACT) + 완성도 critic. critic이 미탐색 단위를 반환하면 상한 내에서 다음 라운드 analyze fan-out으로 재투입(§5).
- 단일 파일·1~2줄 변경엔 이 스킬 금지 — 직접 또는 worker 1개.

## 0.5 재사용 루프 골격
`pipeline(units, analyze, verify)` = 고정 깊이 단발(analyze 1패스 + verify 1패스). 완성도가 필요한 큰 감사는 §5의 critic→verify→재투입 루프를 얹는다.
루프 의미론(트리거·survivor·정지·degraded·천장) SSOT = `~/.claude/workflows/audit-loop.js` 상단 LOOP CONTRACT — 스킬은 dial만 넘긴다: `verifySeverities`·`maxRounds`·`analyzeModel`·`batchSize`(라운드 내 analyze fan-out을 N개씩 끊어 rate-limit cascade 예방)·`critic`(소규모 감사는 `false`).
canonical 호출: `Workflow({scriptPath: '~/.claude/workflows/audit-loop.js', args: {units: [{key, prompt, model?}], context, maxRounds, verifySeverities, analyzeModel, batchSize, critic}})`. §3의 어뷰징·무결성/운영조건·fault-injection 렌즈는 해당 unit에 `model:'opus'` 지정(미지정 unit은 analyzeModel 폴백). §1–6은 그 워크플로의 내부 spec이자, 워크플로 없이 인터랙티브로 돌릴 때의 fallback playbook.
파일 부재 시 → `bash scripts/sync-machine.sh --plugin`으로 `~/.claude/workflows/`에 배치, 그동안은 LOOP CONTRACT대로 §1–6을 인터랙티브 수행.

## 1. 분해
대상을 독립 단위로 나눈다(모듈/레포/레이어/관심사). 각 단위 = 한 워커의 몫.

## 2. 인벤토리 — Haiku tier
**Explore**(read-only·Haiku)로 각 단위의 파일 인벤토리·grep 인덱싱·진입점을 수집. 결론만 받는다 — "무엇이 어디에 있나".

## 3. 분석 fan-out — Sonnet tier
단위별 워커가 병렬 분석. diverse-lens, 각 렌즈 한 줄씩(욱여넣으면 context 압박 시 silent drop):
- 정확성/버그 · 보안 · 성능 · 일관성/중복 · 설정-의도 정합 · 문서-코드 drift
- **핵심 여정 실행성** — 시드/픽스처가 종단 상태를 직접 세팅해 실제 flow를 우회하는 가짜 green smell(`status=finalized` 주입·점수 직접 적재).
- **제품 정체성 SSOT 정합** — README·CLAUDE.md 도메인 불변식/제품명과 모순되는 표면(구 브랜드·렌더러·분류 잔재).
- **제품 의도 복무(product-fit)** — spec·제품 의도 SSOT(프로젝트 CLAUDE.md·README) 대비 이 기능이 어느 핵심 여정에 복무하는지, 고아·죽은 기능. 기준 문서 없으면 사용자 1줄 확인.
- **어뷰징·무결성 불변식** (`model:'opus'`) — 프로젝트 CLAUDE.md `## 도메인 불변식`(스캐폴딩: `~/.claude/templates/domain-invariants.example.md`) 우선, 없으면 README/docs 또는 사용자 확인. 보안(auth/IDOR/injection)과 분리 — '인증상 허용되나 비즈니스룰상 금지'. 4클래스(역할겸직·경제무결성·게이밍·시간축권한)·음성 케이스(self/cross/replay/state-change-after) = 전역/프로젝트 CLAUDE.md '## 작업 방식'의 'green ≠ 금지된 일이 막혔다' 원칙 참조.
- **운영조건/fault-injection** (`model:'opus'`) — 런타임 실패 모드: 외부의존(외부 API·결제·소켓·큐)·상태기계면 타임아웃·부분실패·에러코드·rate-limit·재연결·동시성. 스테이징이 구조적으로 못 보는 환경분기는 'done'이 아니라 '실환경 카나리 전 unknown'으로 표기.
- workflow: `agent(prompt, {model: 'sonnet', effort: 'high', schema})` — effort 명시(미지정이면 세션 effort 상속, fan-out 수만큼 비용 곱해짐).
- 인터랙티브: Task로 `subagent_type: worker` spawn.
- 어뷰징·무결성/운영조건·fault-injection 렌즈만 opus 라우팅(판단 기준은 렌즈 난이도, effort 아님). 재검토 TTL: 분기 1회 paired-run 재실측.

## 4. adversarial 검증 — opus tier (생략 금지)
verify 트리거에 걸린 finding(기본·확장 규칙은 LOOP CONTRACT가 SSOT)을 다른 에이전트가 반증 — 실제 파일/근거 재확인, 거짓양성·과장·지어낸 명령/경로 제거. 살아남은 것만 채택. 불확실하면 보수적으로 의심.
- 검증 tier = **`reviewer`**(Opus, 구조적 read-only — Bash 포함 write 계열 전부 tool 목록에서 제거, SSOT=reviewer.md frontmatter). workflow: `agent(\`반증하라: ${finding}\`, {agentType: 'reviewer', schema: VERDICT})`. 인터랙티브: Task `subagent_type: reviewer`.
- verify끼리 모순이거나 고위험 변경(마이그레이션·배포·자금 경로) 최종 판정이면 메인 tiebreak 1회 — **워크플로 밖에서, 결과를 받은 오케스트레이터가** model 미지정 agent()(=메인 inherit)로 수행. verify tier는 producer보다 낮추지 않는다.

## 5. 완성도 critic → verify 재투입 (opus tier)
별도 렌즈로 "빠진 게 뭔가 — 안 본 모듈·미검증 주장·미확인 가정·안 돌린 렌즈"를 재점검. critic·verify 모두 **`reviewer` tier**.
- critic이 낸 새 finding도 §4 adversarial verify를 한 번 더 통과시켜 살아남은 것만 채택.
- critic이 '안 본 단위'를 반환하고 round < maxRounds면 다음 라운드 분석 fan-out으로 재투입. critic 무소득이거나 상한 도달이면 정지(남은 단위는 units_deferred로 보고).

## 6. 종합 (무손실)
severity로 정렬한 findings + 구체 권고. 반복 결함은 단위별 땜질이 아니라 구조적 처방(공유 모듈/규칙/SSOT).
- critical/high·자금경로·보안 raw finding은 종합 압축이 절대 묻지 못한다. 위임자(메인)는 raw 차원별 리스트를 직접 읽고 보고한다.
- verify/critic이 rate-limit·세션한도로 부분 실패하면 DEGRADED(미검증)로 표기, 낙관 top-line 보류.
- 사용자 판단이 필요한 감사 결과는 매체 SSOT(전역/프로젝트 CLAUDE.md의 시각 산출물 지침)에 따라 raw 차원 리스트를 Artifact 보드로 발행(severity별·before→after). 내부 진행 로그·소규모 감사는 텍스트로 충분.

## 6.5 산출물 durable화 (dated md 생성 금지)
`.ksi/`가 있으면 감사 종점은 dated 스냅샷 md가 아니라 **원장/두뇌 upsert**다. 둘 다 `python3 ~/.claude/scripts/ksi-goals.py --dir <proj>`:
- **findings → 원장:** survivor finding(verify 통과)을 `register --id <G###> --title <finding> --criteria <완료기준>`로 적재(중복은 id로). '완료'는 reviewer 증거 게이트로만.
- **모듈 현황 → 두뇌:** 감사한 모듈을 `state-set --module <경로> --status green|risk|unknown --note "<한줄>" --audit-ref <goal id/근거>`로 upsert. reviewer-confirmed만 등록.
- `.ksi/`가 없으면 → `/goals init` 후 위 두 upsert를 1줄 제안(opt-in). 자금경로·상태전이·멀티세션 프로젝트는 원장화가 기본값.
- **AUDIT_<date>.md 신규 파일 금지** — prose 요약 필요하면 기존 파일 갱신.
- **fleet 전파(어뷰징 finding 한정):** confirmed 어뷰징 finding은 같은 클래스를 공유하는 형제 프로젝트의 `.ksi` 원장에도 proposed goal로 register(대상 맵 SSOT = `~/.claude/templates/domain-invariants.example.md` 'Fleet 전파' 절). verify 통과분만.
- **제품 리스크(fix 안 할 것):** 추적·수용 대상 보안/DB/어뷰징 finding은 goal이 아니라 `ksi-goals.py --dir <proj> risk-add`(플래그는 `--help`가 SSOT). 나중에 고치면 goal로 register, 지금 안 고치면 `risk-accept`(근거 필수). risk는 분리 lifecycle(open→accepted/resolved→regressed).

## 원칙
- dial: exhaustiveness는 항상 최대가 아니라 작업 크기에 비례한다.
- 하네스/프로세스 준수 감사 시: 측정 창 = 해당 규칙·도구의 mtime 이후(그 이전 산출물에 소급 위반 판정 금지).
