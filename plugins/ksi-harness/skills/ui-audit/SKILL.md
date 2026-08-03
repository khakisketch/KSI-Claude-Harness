---
name: ui-audit
description: UI를 코드가 아니라 렌더링된 픽셀로 검증한다. 앱을 띄워 핵심 페이지를 여러 뷰포트(desktop·mobile 390px)로 캡처하고, 스크린샷을 다중 에이전트가 눈으로 감사한 뒤 adversarial하게 검증해 우선순위 findings를 낸다. "타입·e2e는 통과하는데 화면이 깨진다"는 클래스의 결함을 잡는다.
when_to_use: UI 기능을 "완료"하기 직전, 사용자가 화면 깨짐을 보고할 때, 프론트 대량 fan-out 작업 후, 또는 주기적 시각 회귀 점검. 백엔드 검증(ruff/pytest)의 프론트 대응물. **단, 1~2줄 스타일·단일 컴포넌트 변경엔 이 스킬(전량 fan-out) 금지** — CLAUDE.md UI 절의 렌더 확인(desktop+mobile 스크린샷 1회)으로 충분(codebase-audit §0 하한과 대칭).
---

# UI Audit — 픽셀을 본다

전제: **코드가 그럴듯해도 렌더에서 실패한다.** `overflow-auto`가 있어도 한글이 세로로 쪼개지고, 타입이 맞고 e2e가 초록불이어도 모바일 표는 으스러진다. 읽어서는 안 보이고 **봐야만 보인다.** 그래서 반드시 누군가는 스크린샷을 Read로 본다 — fan-out 하되 시각 확인을 프롬프트에 기본 탑재한다.

## 0. 재사용 루프 골격 (매번 0에서 재조립 금지 — codebase-audit §0.5의 픽셀판)
감사·adversarial verify·완성도 critic 루프는 `~/.claude/workflows/audit-loop.js`(saved workflow)를 재사용 — codebase-audit과 **같은 골격**을 픽셀 감사에 쓴다. **캡처(§2)는 골격 밖에서 먼저** 하고, units에 페이지/차원별 프롬프트 + 스크린샷 경로를 넘긴다.
`Workflow({scriptPath: '~/.claude/workflows/audit-loop.js', args: {units:[{key,prompt,model?}], context, verifySeverities, maxRounds, analyzeModel, batchSize, critic}})`
> **파일 부재 = 플러그인 머신에 workflow 미배치**(플러그인 번들은 workflows/를 안 나른다) → `bash scripts/sync-machine.sh --plugin`으로 `~/.claude/workflows/` 배치. 그동안은 §1–6 인터랙티브(조용한 강등 아님).
- **루프 의미론(트리거·survivor·정지·degraded·폴백)의 SSOT = audit-loop.js 상단 LOOP CONTRACT 주석** — 여기서 재명세하지 않는다(산문↔코드 drift 차단). dial: verifySeverities·maxRounds·analyzeModel·batchSize(rate-limit cascade 예방 — §6 DEGRADED 경고와 연결)·critic(소규모 감사는 false로 생략)(기본값 SSOT=audit-loop.js LOOP CONTRACT — 여기 수치는 편의 표기).
- **티어링(픽셀판):** 캡처·인벤토리=haiku(Explore) · 시각 감사=`model:'sonnet'` · **발견성·역할게이팅·흐름단절 등 맥락추론 렌즈=`model:'opus'`**(해당 unit에 `model:'opus'`를 지정하는 것이 canonical 호출 — 미지정 unit은 analyzeModel 폴백) · verify/critic=reviewer(LOOP CONTRACT) · 종합=메인. 모델 배치 일반 규칙은 CLAUDE.md 참조. **(Sonnet 5세대 기준)** 맥락추론 렌즈의 opus 라우팅은 **미변경** — sonnet 기본화(비용↓)는 paired-run 스팟체크 후 결정(과거 '빈 보고서 첫인상' 회귀 선례상 신중. 재검토 TTL: 분기 1회 paired-run 재실측).
- **context에 design-side spec을 반드시 넣는다** — UX목표 5축(페르소나·동선 step-budget·상태 인벤토리·마이크로카피 SSOT·접근성 예산 = CLAUDE.md UI 절 SSOT). 기준 없는 시각 감사는 '안 깨졌나'만 잰다.

## 절차

1. **대상 확정**
   - 페이지/라우트 목록: 변경된 화면 + 핵심 흐름(목록·상세·폼·대시보드·빈상태).
   - 뷰포트 set: **mobile 390px** (필수), tablet 768, desktop 1440. 모바일을 빼지 않는다.
   - 데이터: 풍부한 mock 말고 **빈 / 희박(1~2행) / 아주 긴 한글 이름 / 다수 행**을 섞은 픽스처로.
   - **콜드스타트 시나리오:** 빈 조직 + **각 역할로 로그인한 첫 화면**. 픽셀 한 장이 아니라 **동선**을 캡처 — "핵심 산출물(리포트·결과)까지 nav에서 몇 클릭에 도달하나, 못 찾나, 클릭하면 리다이렉트되는 죽은 메뉴는 없나".
   - **측정 기준(design-side spec)을 먼저 확보:** §0의 UX목표 5축(=CLAUDE.md SSOT). 없으면 PRD/`docs/`에서 추출하거나 사용자에게 1줄 확인. **시각 감사는 '안 깨졌나'가 아니라 '이 목표 대비 gap이 있나'를 본다** — 기준 없는 감사는 '잘 구성됐나'만 통과시킨다.

2. **캡처 — 실행 위치 라우팅** (캡처만 CPU-heavy — 판독 fan-out(§3)은 API 에이전트라 로컬 CPU 무관. 경합 박스에선 "더 병렬"이 아니라 "밖으로 빼거나(CI) 줄 세우기(락)"):
   - **preflight(필수):** `bash ~/.claude/scripts/load-guard.sh check` — RED(exit 2)면 CI 경로 우선. 로컬이 불가피하면(CI 미채택 레포 등) **막지 말고 저강도로 진행**(capture.mjs가 자동 감속: self-nice 10·동시성 1)하되 지연·부분실패 가능성을 사용자에게 1줄 보고. YELLOW는 경고 후 진행. (임계값·락 대기 노브 SSOT=스크립트 헤더)
   - **local(기본):** `/run`·`/verify`로 앱 기동 → 일괄 캡처는 `node ~/.claude/scripts/capture.mjs --pages <pages>`(픽셀-중립 효율 러너: reduced-motion·애니메이션 고정, 고신뢰 트래커만 차단, 부하 적응 동시성, self-nice. **폰트/이미지 차단 등 픽셀을 바꾸는 최적화는 금지** — 감사 입력 오염) · 동선·인터랙션 캡처만 playwright-mcp. 캡처 명령은 `load-guard.sh run -- <cmd>`로 감싼다(flock 직렬화 — 동시 세션의 Chromium 중첩 기동 방지. **병렬은 캡처가 아니라 판독·verify에서**). 기동 불가면 사용자에게 실행 방법을 1줄로 묻는다.
   - **CI(load RED·멀티프로젝트 동시 감사·정례 회귀):** `~/.claude/templates/visual-qa.yml`을 repo `.github/workflows/`에, `~/.claude/scripts/capture.mjs`를 repo `scripts/visual-qa-capture.mjs`로 복사 채택(local과 같은 러너로 수렴 — repo 반영·push은 사용자 승인 사항) → 러너가 캡처 후 아티팩트 업로드 → `gh run download -n visual-qa-shots`로 받아 **§3부터는 평소처럼 로컬 하네스가 수행**(adversarial verify가 같은 픽셀을 다시 보는 루프 무손상). 러너=프로젝트별 독립·병렬 by design — **멀티프로젝트 병렬 시각 감사의 canonical 경로.**
   - Agent `isolation:"remote"`는 이 경로의 기본이 아니다 — 환경에 따라 remote 스폰이 같은 호스트로 **조용히 강등**될 수 있다(가용성 gated — 첫 응답 "ok"만으론 가용 오판). 판별 probe(hostname·loadavg·파일시스템 비교)로 진짜 격리가 실측 확인된 환경에서만 고려하고, 그 전까지 원격 캡처=CI.

3. **시각 감사 (fan-out)** — 페이지(또는 뷰포트)별로 에이전트를 띄워 **스크린샷을 Read로 보게** 하고 결함을 분류 보고:
   - 오버플로 / 클리핑 / 가로 스크롤
   - **한글 텍스트 세로 쪼개짐**("박/명/숙") → `word-break: keep-all` 누락
   - 터치 타겟 < 44px, 노안 고려 글자 크기
   - 대비(WCAG AA), 색 의존 정보
   - 빈 / 희박 / 초과 상태에서의 깨짐 (특히 차트·표)
   - **발견성/콜드스타트:** 핵심 산출물(리포트·결과)이 nav에서 도달 가능한가 · 신규/각 역할이 길을 잃나 · 클릭하면 리다이렉트되는 죽은 메뉴는 없나 · 기능이 '만든 사람 머릿속' 위치(예: 산출물이 관리 메뉴 깊숙이)에 묻혀 있나. (화면 안 깨졌어도 도달 못 하면 결함)
   - **흐름 마찰(시각 너머):** 핵심 잡(생성→검수→최종화→산출물)을 몇 단계·클릭에 끝내나 · 중복 경로 · 숨은 1차 CTA · 되돌리기 없는 위험 동작. **단계 예산 초과는 화면이 안 깨졌어도 결함**(design-side spec의 step-budget 대비).
   - **에러·복구·엣지('green≠작동'의 UI판):** parse 실패·필수값 누락·권한 차단·finalize 잠금에서 사용자가 막히지 않고 빠져나오나 · 에러 메시지가 raw 키/영어/HTTP코드가 아니라 사람 말인가 · 미리 최종화된 픽스처가 아니라 실제 상태(빈/생성중/실패)가 렌더되나.
   - **용어 SSOT·마이크로카피:** 같은 개념이 화면마다 다른 라벨로 새지 않나 — **라벨 SSOT 파일(labels.ts 등)을 스크린샷과 함께 Read해 실제 표기와 대조** · 내부코드(group_code·reason_code 등)·영어 잔존 노출 · 빈 상태 문구가 다음 행동을 안내하나. (실제 프로젝트에서 이중 분류 SSOT 모순·영어 raw 에러가 이 렌즈에서 나온 선례가 있다.)
   - 정렬·간격 드리프트, 이모지 vs 아이콘 혼용 등 일관성
   - *(시각 렌즈 외 맥락추론 렌즈 — 발견성·흐름마찰·에러복구 — 는 §0 티어링대로 opus로 라우팅)*

4. **adversarial 검증 + 완성도 critic → 재투입** — 각 critical/high finding(기본 — dial로 확장)을 *다른* 에이전트(**`reviewer` tier** — opus·xhigh·**구조적 read-only**: Bash 포함 write 계열 전부 tool 목록에서 제거, 상세는 reviewer.md frontmatter가 SSOT)가 같은 스크린샷으로 반증 시도(거짓양성·과장 제거). 살아남은 것만 채택. 인터랙티브 경로는 Task로 `subagent_type: reviewer` spawn.
   - **완성도 critic(reviewer):** 안 본 페이지·뷰포트·역할·빈/초과 상태가 남았나 1패스 재점검. **critic이 낸 새 결함도 위 adversarial verify를 한 번 더 통과시켜 채택**(critic 산출물 무검증 통과 금지), 남은 게 있고 상한(maxRounds, 기본값 SSOT=audit-loop.js LOOP CONTRACT) 내면 재캡처·재감사. codebase-audit §5와 대칭의 수렴 루프 — ui-audit이 선형이라 빠졌던 단계.
   - **실행형 골격:** §0 재사용 루프 골격 참조(audit-loop.js — 캡처(§2)는 골격 밖에서 먼저).

5. **구조적 처방** — 여러 페이지에 반복되는 결함은 페이지별 땜질이 아니라 **공유 프리미티브로 한 번에**: `PageHeader` / `ResponsiveTable`(모바일 reflow) / `EmptyState` / 라벨 맵(SSOT). 일관성을 노력이 아니라 구조로 강제.

6. **우선순위 findings + (선택) 회귀 baseline** — severity로 정렬해 보고. **무손실/DEGRADED(codebase-audit §6과 대칭): critical/high 시각 결함은 종합 요약이 묻지 못한다 · verify/critic이 부분 실패하면 audit-loop이 `degraded:true`를 반환 — 그 플래그가 서면 낙관 결론('시각적으로 멀쩡')을 보류한다(green≠작동의 UI판).** 수정 후 재캡처로 회귀 확인하고, 핵심 화면은 baseline 스크린샷을 저장해 다음 diff의 기준으로 남긴다. **user-visible 변경이고 디자인 방향이 사용자 판단 사항이었으면, baseline과 수정 후 스크린샷을 나란히 before→after Artifact 보드로 발행**(매체 SSOT=CLAUDE.md UI 절 — **스크린샷은 base64 data URI로 실제 embed, 경로 텍스트만 적은 보드는 결함**) — baseline이 이미 저장돼 있어 한계비용 최저. 단 1~2줄 CSS·저위험 변경엔 render Read로 충분(전량 fan-out 금지선과 대칭). 무손실 규칙은 보드에서도 유지 — 보드가 critical/high 결함을 예쁘게 묻으면 안 된다.

## 원칙
- **모바일을 빼지 않는다.** 결함의 대부분은 390px에서 처음 보인다.
- **풍부한 mock의 함정.** 빈·희박·초과 상태로 봐야 진짜 깨짐이 드러난다.
- **발견성도 본다.** "화면이 안 깨졌나"만이 아니라 "신규 사용자가 핵심 산출물에 도달하나". 메뉴 부재·역할 게이팅·죽은 링크는 빈 조직 + 역할별 콜드스타트로만 드러난다(만든 사람 머릿속 ≠ 신규 사용자 눈).
- **한글 기본값:** `word-break: keep-all`, 표는 세로 reflow.
- fan-out의 맹점: 에이전트 누구에게도 "픽셀을 보라"고 안 시키면 시각맹점이 시스템화된다. **시각 확인을 기본 탑재.**
