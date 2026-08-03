---
name: codebase-audit
description: 코드베이스/모듈을 여러 에이전트로 병렬 감사·분석하고, 발견을 adversarial하게 검증한 뒤 우선순위 findings로 종합한다. ui-audit의 백엔드·일반 코드 대응물 — "픽셀" 대신 코드·설정·문서를 본다. 병렬 감사가 실익일 때 그 골격을 매번 0에서 재조립하지 않기 위한 재사용 스캐폴딩.
when_to_use: substantive한 코드 감사·병렬 분석이 필요할 때 — 여러 모듈/레포 동시 점검, 리팩터/마이그레이션 전 현황 파악, 버그·취약점·일관성·완성도 sweep. 단일 파일 1~2개 조회는 쓰지 말 것(오버킬).
---

# Codebase Audit — 병렬 감사 → adversarial 검증 → 종합

ui-audit이 프론트 "픽셀"에 하는 일을 백엔드/일반 코드에 한다. 핵심 두 원칙:
**적재적소 티어링**(탐색=haiku · 분석/구현=sonnet · verify=opus · 모순 tiebreak/고위험 최종=메인)과 **adversarial 검증**(값싼 워커는 그럴듯한 거짓을 만든다 — 반드시 반증으로 거른다. 이 하네스에서 반복 적발됨).

## 0. 스코프 dial (먼저 — 적정규모가 기본: 최소 실행에서 시작해, 필요가 정당화할 때만 dial-up)
- 작은 substantive: 워커 1개 + 검증 1패스.
- 중간: 모듈 N개 = 워커 N개, adversarial 1패스.
- 큰 감사: fan-out + adversarial(새 finding 마를 때까지, maxRounds dial로 라운드 상한 — 기본값 SSOT=audit-loop.js LOOP CONTRACT, 여기 수치는 편의 표기) + 완성도 critic. **확장 옵션:** critic이 미탐색 단위를 반환하면 상한 내에서 다음 라운드 analyze fan-out으로 자동 편입(§5 재투입 루프) — 고정 분해로 안 본 표면이 남을 때.
- 단일 파일·1~2줄 변경엔 이 스킬 금지 — 직접 또는 worker 1개(코드 수정에 scout/Haiku 금지).

## 0.5 재사용 루프 골격 (매번 0에서 재조립 금지 — 의미를 못박는다)
`pipeline(units, analyze, verify)`는 **고정 깊이 단발**(analyze 1패스 + verify 1패스)이다. 완성도가 필요한 큰 감사는 §5의 critic→verify→재투입 루프를 얹어 수렴시킨다.
**루프 의미론(트리거·survivor·정지·degraded·천장)의 SSOT = `~/.claude/workflows/audit-loop.js` 상단 LOOP CONTRACT 주석.** 여기서 재명세하지 않는다(산문↔코드 drift 차단) — 스킬은 dial만 넘긴다: `verifySeverities`·`maxRounds`·`analyzeModel`·`batchSize`(라운드 내 analyze fan-out을 N개씩 끊어 rate-limit cascade 예방 — §6 DEGRADED 경고와 연결)·`critic`(소규모 감사는 `false`로 생략)(기본값 SSOT=audit-loop.js LOOP CONTRACT — 여기 수치는 편의 표기).
**canonical 경로 = audit-loop.js workflow.** `Workflow({scriptPath: '~/.claude/workflows/audit-loop.js', args: {units: [{key, prompt, model?}], context, maxRounds, verifySeverities, analyzeModel, batchSize, critic}})`로 호출. §3의 어뷰징·무결성/운영조건·fault-injection처럼 opus 라우팅이 필요한 렌즈는 해당 unit에 `model:'opus'`를 지정하는 것이 canonical 호출(미지정 unit은 `analyzeModel` 폴백). **§1–6은 그 워크플로가 내부 수행하는 spec이자, 워크플로 없이 인터랙티브로 돌릴 때의 fallback playbook**이다. **파일 부재 = 플러그인 머신에 workflow 미배치**(플러그인 번들은 workflows/를 자동설치 안 함 — `${CLAUDE_PLUGIN_ROOT}`도 스킬 prose에선 확장 안 됨) → `bash scripts/sync-machine.sh --plugin`으로 `~/.claude/workflows/`에 배치하거나, 그동안 LOOP CONTRACT대로 §1–6을 인터랙티브 author(조용한 강등이 아니라 명시적 fallback).

## 1. 분해
대상을 독립 단위로 나눈다(모듈/레포/레이어/관심사). 각 단위 = 한 워커의 몫.

## 2. 인벤토리 — Haiku tier
`scout`(쓰기 필요 시) 또는 빌트인 **Explore**(read-only, 이미 Haiku)로 각 단위의 파일 인벤토리·grep 인덱싱·진입점을 빠르고 싸게 수집.

## 3. 분석 fan-out — Sonnet tier
단위별 워커가 병렬 분석. **diverse-lens** — 각 렌즈를 한 줄씩(압축해 한 문단에 욱여넣으면 context 압박 시 렌즈가 silent drop된다):
- 정확성/버그 · 보안 · 성능 · 일관성/중복 · 설정-의도 정합 · 문서-코드 drift
- **핵심 여정 실행성** — 시드/픽스처가 파생·종단 상태를 직접 세팅해 실제 flow를 우회하는 '가짜 green' smell(`status=finalized` 주입·점수 직접 적재). 데모는 차 있는데 실사용 동선은 막혀 있나.
- **제품 정체성 SSOT 정합** — README·CLAUDE.md 도메인 불변식/제품명과 모순되는 표면(피벗·리네이밍 후 구 브랜드·렌더러·분류 잔재 누수).
- **제품 의도 복무(product-fit)** — 착수 spec·제품 의도 SSOT(프로젝트 CLAUDE.md·README) 대비 이 기능/메뉴가 어느 핵심 여정에 복무하는지, 고아·죽은 기능은 없는지. 기준 문서가 없으면 사용자 1줄 확인(기준 없는 감사는 '안 깨졌나'로 퇴화).
- **어뷰징·무결성 불변식** *(맥락추론 — `model:'opus'` 라우팅)* — 먼저 프로젝트 CLAUDE.md의 `## 도메인 불변식` 섹션(스캐폴딩: `~/.claude/templates/domain-invariants.example.md`)을 로드해 구체값을 측정 기준으로 — 없으면 README/docs에서 추출하거나 사용자 1줄 확인. 형제 모듈 대조는 보조. 보안(auth/IDOR/injection)과 **분리**: '인증상 허용되나 비즈니스룰상 금지'. **4 어뷰징클래스(역할겸직·경제무결성·게이밍·시간축권한)·음성 케이스(self/cross/replay/state-change-after) = CLAUDE.md '검증과 보고'의 'green ≠ 막혔다' 절 참조.** happy-path가 green이어도 음성 케이스 안 태우면 이 클래스는 영원히 green.
- **운영조건/fault-injection** *(맥락추론 — `model:'opus'` 라우팅)* — 정적 코드가 아니라 런타임 실패 모드: 외부의존(거래소·결제·소켓·큐)·상태기계면 타임아웃·부분체결·에러코드·rate-limit·재연결·동시성에서 어떻게 깨지나. **스테이징/testnet이 구조적으로 못 보는 환경분기가 있으면 'done'이 아니라 '실환경 카나리 전 unknown'으로 표기.**
- workflow: `agent(prompt, {model: 'sonnet', effort: 'high', schema})` — **effort 명시(P1' 2축 배치)**: 미지정이면 세션 effort(ultracode=xhigh)를 상속해 fan-out 수만큼 사고 비용이 곱해진다. 정형 분석=high로 충분(런타임 `agent({effort})` 지원 실측 확인 2026-07-18).
- 인터랙티브: Task로 `subagent_type: worker` spawn (worker.md가 Sonnet+effort 고정)
- 어려운 추론이 필요한 단위만 `'opus'`로. (0.9.0: analyze 기본 effort=high 명시로 "xhigh 상속" 구모델 서술은 삭제 — opus 라우팅 판단 기준은 effort가 아니라 렌즈 난이도.) 어뷰징·무결성/운영조건·fault-injection 렌즈의 opus 라우팅은 실측으로 **유지 확정**(근거·이력=memory `harness-design-principles`가 SSOT — 여기 복제 안 함. 재검토 TTL: 분기 1회 paired-run 재실측).

## 4. adversarial 검증 — opus tier (생략 금지)
각 critical/high finding(기본 — dial로 medium 이하 확장)을 **다른 에이전트가 반증 시도** — 실제 파일/근거를 다시 열어 거짓양성·과장·지어낸 명령/경로를 거른다. 살아남은 것만 채택. 확실치 않으면 보수적으로 의심. (§0.5 verify 트리거와 동일 기준 — 절마다 다르게 읽히면 안 된다.)
- 검증 tier = **`reviewer`**(Opus xhigh, **구조적 read-only** — 2026-07-16부터 Bash 포함 write 계열 전부 tool 목록에서 제거, 상세는 reviewer.md frontmatter가 SSOT. 트레이드오프: 테스트 실행 같은 동적 검증은 reviewer가 못 하므로 메인에 위임). workflow: `agent(\`반증하라: ${finding}\`, {agentType: 'reviewer', schema: VERDICT})` (`{model:'opus'}`도 동작하나 reviewer면 effort·read-only가 frontmatter로 고정). 인터랙티브: Task로 `subagent_type: reviewer` spawn.
- **verify끼리 모순이거나 고위험 변경(마이그레이션·배포·자금 경로)의 최종 판정이면 메인 tiebreak 1회** — model 미지정 agent()(=메인 inherit)로. 메인 fan-out은 이 경우뿐(audit-loop.js 내부 동작이 아니라 결과 수신 후 오케스트레이터가 수행). **(2026-07-01) Sonnet 5가 싸고 near-Opus라도 verify tier는 sonnet으로 안 내린다** — producer(worker=sonnet)와 같은 weight면 blind spot이 correlated라 반증이 죽는다(cross-model opus skeptic이 핵심). 비용은 하네스상 downgrade 기준이 아님.

## 5. 완성도 critic → verify 재투입 (수렴 루프, opus tier)
별도 렌즈로 "빠진 게 뭔가 — 안 본 모듈·미검증 주장·미확인 가정·안 돌린 렌즈"를 재점검. critic·verify 모두 **`reviewer` tier**(§4) — 둘은 같은 opus read-only 검증 에이전트의 두 모드(반증 vs 완성도)일 뿐 별도 에이전트가 아니다.
- **critic 산출물을 그냥 채택하지 않는다** — critic이 낸 새 finding도 §4 adversarial verify를 한 번 더 통과시켜 살아남은 것만 채택(값싼 critic도 그럴듯한 거짓을 낸다 — verify 우회 금지). 1차 findings는 verify로 걸렀는데 critic 추가분만 무검증 통과하는 게 흔한 누락이다.
- critic이 '안 본 단위'를 반환하고 round < maxRounds(기본값 SSOT=audit-loop.js LOOP CONTRACT)면 그 단위를 **다음 라운드의 분석 fan-out으로 재투입**. critic 무소득이거나 상한 도달이면 정지(남은 단위는 audit-loop이 units_deferred로 보고). (pipeline은 고정 깊이 단발이므로, 이 재투입이 없으면 critic은 루프가 아니라 terminal one-shot이 된다.)

## 6. 종합 (무손실)
severity로 정렬한 findings + 구체 권고. 반복 결함은 단위별 땜질이 아니라 **구조적 처방**(공유 모듈/규칙/SSOT). **무손실 규칙: critical/high·자금경로·보안 raw finding은 종합 압축이 절대 묻지 못한다** — '대체로 production-grade' 같은 top-line이 그 아래 critical을 가리면 안 된다. 위임자(메인)는 종합 *요약문*이 아니라 **raw 차원별 리스트를 직접 읽고 보고**한다. verify/critic이 rate-limit·세션한도로 부분 실패하면 그 결과를 **DEGRADED(미검증)**로 표기하고 낙관 top-line을 보류한다(잘린 draft를 '완료'로 relay 금지). **사용자 판단이 필요한 감사 결과는 매체 SSOT(CLAUDE.md UI)에 따라 raw 차원 리스트를 Artifact 보드로 발행**(severity별·before→after — 텍스트벽 대신, ui-audit §6과 대칭). 보드도 무손실 — critical/high를 예쁘게 묻지 않는다. 내부 진행 로그·소규모 감사는 텍스트로 충분(세리모니 전가 금지).

## 6.5 산출물 durable화 (읽고 버리지 않기 — 2026-07-16, dated md 생성 금지)
감사 결과를 세션과 함께 휘발시키지 마라(자가감사 실측: '전체 분석해줘'를 프로젝트마다 반복하는 마찰의 근본원인이 산출물 비내구성 — AUDIT_<date>.md 난립이 그 증상). substantive 감사 종점은 **dated 스냅샷 md가 아니라 원장/두뇌 upsert**다(`.ksi/`가 있을 때). 두 write-path 모두 `python3 ~/.claude/scripts/ksi-goals.py --dir <proj>`:
- **findings → 원장(할 일):** survivor finding(verify 통과)을 `register --id <G###> --title <finding> --criteria <완료기준>`으로 proposed goal 적재(중복은 id로). '완료'는 자기신고가 아니라 reviewer 증거 게이트로만.
- **모듈 현황 → 두뇌(무엇이 있나):** 감사한 각 모듈을 `state-set --module <경로> --status green|risk|unknown --note "<한줄>" --audit-ref <goal id 또는 근거>`로 upsert. state는 git HEAD로 freshness 스탬프돼, 다음 SessionStart에 goal-status.sh가 '현황+stale(코드 변경 후 미재감사)'을 복원 → **다음 세션이 재분석 대신 '두뇌 읽고 이어가기'**가 된다. reviewer-confirmed만 등록(원장/두뇌 노이즈 방지).
- `.ksi/`가 없으면 → `/goals init` 후 위 두 upsert를 1줄 제안(원장 채택은 opt-in — 사용자 확인 후. 세션시작 자동 원장화 넛지[goal-status path B]는 저신호라 0.8.4에서 제거됨 — 이 제안이 유일한 채택 경로다). 자금경로·상태전이·멀티세션 프로젝트는 원장화가 기본값.
- **AUDIT_<date>.md 신규 파일은 만들지 마라** — 그게 휘발·재분석의 근원. 굳이 prose 요약이 필요하면 기존 파일 갱신(신규 dated 파일 금지).
- **fleet 전파(어뷰징 finding 한정):** '어뷰징·무결성' 렌즈가 confirmed 어뷰징 finding을 내면, 같은 클래스를 공유하는 형제 프로젝트에도 거의 항상 존재한다 — 그 음성 케이스를 형제의 `.ksi` 원장에 proposed goal로 register한다(전파 대상 맵·규율 SSOT = `~/.claude/templates/domain-invariants.example.md`의 'Fleet 전파' 절). verify 통과분만 전파(환각 확산 금지).
- **제품 리스크 기록(fix 안 할 것·수용할 것):** 지금 고칠 게 아니라 **추적·수용** 대상인 보안/DB/어뷰징 finding은 goal이 아니라 risk로 — `ksi-goals.py --dir <proj> risk-add`(정확한 플래그는 `ksi-goals.py --help`가 SSOT). 나중에 고치면 그 finding을 goal로 register(→goals-run 자율소진), 지금 안 고치기로 하면 `risk-accept`(baseline — 근거 필수). goal의 completion 술어를 오염시키지 않게 risk는 분리 lifecycle(open→accepted/resolved→regressed). goal-status가 SessionStart에 미해소 risk를 복원.

## 원칙
- **티어링(3-tier 워커 + 메인):** 탐색=Explore/scout(`'haiku'`) · 분석·구현=worker(`'sonnet'`) · verify·완성도 critic=**reviewer**(`'opus'`·xhigh·read-only) · 모순 tiebreak/고위험 최종=메인(미지정 inherit, 의도적으로만) · 판정·종합=메인(어느 모델이든 무관). 모델은 alias로 지정 — 풀 ID 하드코딩 금지.
- **adversarial 필수:** 검증 안 거친 발견은 채택하지 않는다(critical/high 기본 — 미만 severity는 정책적 skip 후 unverified 표기 채택).
- **dial:** exhaustiveness는 "항상 최대"가 아니라 작업 크기에 비례해.
- **하네스/프로세스 준수 감사 시:** 측정 창 = 해당 규칙·도구의 mtime 이후(그 이전 산출물에 신규 규칙 소급 위반 판정 금지).
