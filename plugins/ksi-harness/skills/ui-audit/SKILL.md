---
name: ui-audit
description: UI를 코드가 아니라 렌더링된 픽셀과 실제 동선으로 검증한다. 앱을 띄워 핵심 페이지를 여러 뷰포트(mobile 390·tablet 768·desktop 1440)로 캡처하는 '페이지 레인'과, 페르소나가 자기 브라우저로 업무를 완수해보는 '여정 레인'을 대칭으로 돌린 뒤 adversarial 검증·메인 재측정으로 우선순위 findings를 낸다. "타입·e2e는 통과하는데 화면이 깨진다"와 "화면은 멀쩡한데 일이 안 된다" 두 클래스를 함께 잡는다.
when_to_use: UI 기능을 "완료"하기 직전, 사용자가 화면 깨짐을 보고할 때, 프론트 대량 fan-out 작업 후, 또는 주기적 시각 회귀 점검. 백엔드 검증(ruff/pytest)의 프론트 대응물. **단, 1~2줄 스타일·단일 컴포넌트 변경엔 이 스킬(전량 fan-out) 금지** — CLAUDE.md UI 절의 렌더 확인(390/768/1440 스크린샷 1회)으로 충분(codebase-audit §0 하한과 대칭).
---

# UI Audit — 픽셀을 본다

코드가 그럴듯해도 렌더에서 실패한다 — 타입·e2e가 통과해도 모바일 표는 으스러지고 한글이 세로로 쪼개진다. 읽어서는 안 보이고 봐야 보인다: fan-out 시 스크린샷을 Read로 보는 시각 확인을 프롬프트에 기본 탑재한다.

## 0. 루프 골격
감사·adversarial verify·완성도 critic 루프는 `~/.claude/workflows/audit-loop.js`(saved workflow) 재사용. 캡처(§2)는 골격 밖에서 먼저 하고, units에 페이지/차원별 프롬프트 + 스크린샷 경로를 넘긴다.
`Workflow({scriptPath: '~/.claude/workflows/audit-loop.js', args: {units:[{key,prompt,model?}], context, verifySeverities, maxRounds, analyzeModel, batchSize, critic}})`
> 파일 없으면 `/ksi-setup`(플러그인 설치) 또는 `bash scripts/sync-machine.sh --plugin`(repo clone)으로 `~/.claude/workflows/` 배치. 그동안은 §1–6을 인터랙티브로.
- 루프 의미론(트리거·survivor·정지·degraded·폴백)은 audit-loop.js 상단 LOOP CONTRACT 참조. dial: verifySeverities·maxRounds·analyzeModel·batchSize(rate-limit 예방)·critic(소규모는 false).
- 티어링: 캡처·인벤토리=haiku(Explore) · 시각 감사=`model:'sonnet'` · 발견성·역할게이팅·흐름단절=`model:'opus'`(unit별 지정, 미지정은 analyzeModel 폴백) · verify/critic=reviewer · 종합=메인.
- context에 design-side spec(페르소나·동선 step-budget·상태 인벤토리·마이크로카피 SSOT·접근성 예산 = CLAUDE.md UI 절)을 반드시 넣는다 — 기준 없는 감사는 '안 깨졌나'만 본다.

## 절차

1. **대상 확정**
   - 페이지/라우트: 변경 화면 + 핵심 흐름(목록·상세·폼·대시보드·빈상태).
   - 뷰포트: mobile 390px(필수) · tablet 768(필수 — `md:` 브레이크포인트가 태블릿에서 본문을 폰보다 좁힐 수 있음) · desktop 1440.
   - 데이터: 빈 / 희박(1~2행) / 아주 긴 한글 이름 / 다수 행을 섞은 픽스처.
   - 상태 인벤토리에 인터랙션 상태 포함 — 열린 팝오버·드롭다운·모달, 저장 중 버튼, 오프라인 실패, 인쇄 미디어, 검증 에러. §2의 `do` 스텝으로 캡처(안 하면 감사되지 않은 것).
   - 콜드스타트: 빈 조직 + 각 역할 첫 로그인 화면. 핵심 산출물까지 nav 클릭 수·도달 불가·죽은 메뉴 확인.
   - 측정 기준(§0의 design-side spec) 먼저 확보 — 없으면 PRD/`docs/`에서 추출하거나 사용자에게 1줄 확인.

2. **캡처 — 실행 위치 라우팅**
   - preflight(필수): `bash ~/.claude/scripts/load-guard.sh check` — RED(exit 2)면 CI 경로 우선. 로컬 불가피 시 저강도 진행(capture.mjs 자동 감속: self-nice 10·동시성 1), 지연 가능성 1줄 보고. YELLOW는 경고 후 진행.
   - local(기본): `/run`으로 앱 기동 → `node ~/.claude/scripts/capture.mjs --pages <pages>`(reduced-motion 고정, 고신뢰 트래커만 차단, 부하 적응 동시성. 폰트/이미지 차단 등 픽셀을 바꾸는 최적화 금지). `load-guard.sh run -- <cmd>`로 감싼다(flock 직렬화). 기동 불가면 사용자에게 방법을 1줄로 묻는다.
     - 인증 앱은 `--setup <hook.mjs>` 필수 — 없으면 전 페이지가 로그인 화면 사본인데도 성공 보고될 수 있다. 훅 시그니처: `export default async function setup(page, {base, viewport})`. 역할별 감사는 env(`QA_ROLE`)로 분기.
     - `do` 스텝으로 인터랙션 상태 캡처 — `{key, path, do:[{click:sel},{fill:sel,value},{select},{press},{hover},{scroll},{wait},{waitFor},{offline},{emulate:'print'}]}`. 정지 URL만 캡처하면 팝오버·오프라인 등 결함은 안 보인다.
     - 캡처 후 `manifest.json`을 픽셀보다 먼저 읽는다 — 샷별 `finalUrl`·`redirected`·`sha1`·`consoleErrors`·`failedRequests`로 죽은 메뉴·CSP 차단·API 실패가 판독 전에 드러난다.
     - DEGRADED(exit 3): ① 서로 다른 key가 동일 픽셀 ② 절반 이상 로그인 리다이렉트. 이 경우 판독을 시작하지 않고 원인 제거 후 재캡처(의도된 동일 픽셀이면 `--allow-identical`).
   - CI(load RED·멀티프로젝트·정례 회귀): `~/.claude/templates/visual-qa.yml`을 `.github/workflows/`에, `~/.claude/scripts/capture.mjs`를 `scripts/visual-qa-capture.mjs`로 복사(push은 사용자 승인) → 러너가 캡처·아티팩트 업로드 → `gh run download -n visual-qa-shots`로 받아 §3부터 로컬에서 진행.
   - Agent `isolation:"remote"`는 이 경로에 쓰지 않는다 — 로컬과 같은 호스트로 강등돼 격리 실익 없음. 원격 캡처는 CI로.

3. **감사 fan-out — 두 레인을 대칭으로 돌린다.**

   **3-A. 페이지 레인(픽셀 판독)** — 페이지/뷰포트별 에이전트가 스크린샷을 Read로 보고 결함 분류 보고:
   - 오버플로 / 클리핑 / 가로 스크롤
   - 한글 텍스트 세로 쪼개짐("박/명/숙") → `word-break: keep-all` 누락
   - 터치 타겟 < 44px, 노안 고려 글자 크기
   - 대비(WCAG AA), 색 의존 정보
   - 빈 / 희박 / 초과 상태에서의 깨짐(특히 차트·표)
   - 발견성/콜드스타트: 핵심 산출물이 nav에서 도달 가능한가 · 신규/역할별 사용자가 길을 잃나 · 죽은 메뉴 · 기능이 관리 메뉴 깊숙이 묻혀 있나
   - 흐름 마찰: 핵심 잡을 몇 단계·클릭에 끝내나 · 중복 경로 · 숨은 1차 CTA · 되돌리기 없는 위험 동작(step-budget 대비 초과는 결함)
   - 에러·복구·엣지: parse 실패·필수값 누락·권한 차단·finalize 잠금에서 빠져나올 수 있나 · 에러 메시지가 raw 키/영어/HTTP코드가 아닌 사람 말인가 · 실제 상태(빈/생성중/실패)가 렌더되나
   - 용어 SSOT·마이크로카피: 라벨 SSOT 파일(labels.ts 등)을 스크린샷과 대조 · 내부코드(group_code 등)·영어 잔존 노출 · 빈 상태 문구가 다음 행동을 안내하나
   - 정렬·간격 드리프트, 이모지 vs 아이콘 혼용
   - 발견성·흐름마찰·에러복구는 §0 티어링대로 opus로 라우팅

   **3-B. 여정 레인(페르소나가 실제로 업무 수행)** — 페이지 레인과 동시에 돌린다. 규모가 작으면 유닛 수만 줄이고 레인 자체는 생략하지 않는다.
   - 정지 스크린샷만으로는 팝오버 위치·소프트 내비게이션 필터·중복 제출 등 상호작용 결함이 안 보인다.
   - 유닛 = 페르소나 × 완수할 업무. 최소 3레인: ① 매일 쓰는 실무자 ② 가끔 들어오는 관리자 ③ 오늘 처음 켠 신규 사용자(빈 DB). 외부 수신자(고객·보호자·감사관)가 있으면 한 레인 더.
   - 에이전트마다 자기 브라우저: `node ~/.claude/scripts/journey.mjs --setup <hook> --out <dir> --paths <...> --viewport tablet-768,mobile-390`(스크린샷 + 터치타겟<44px·표 가로잘림·입력 min/max·콘솔에러·리다이렉트 실측). 더 깊은 인터랙션은 이 파일을 복사. playwright-mcp는 단일 브라우저라 fan-out 불가 — 이 경로를 쓴다.
   - 각 여정은 몇 단계 걸렸나 / 어디서 막혔나 / 성공·부분성공·실패를 보고(step-budget 대비). 화면이 안 깨졌어도 목표 미달성은 결함.
   - 콜드스타트는 별도 빈 스택으로 — 빈 DB로 API/WEB 포트 분리 기동 후 가입부터 첫 산출물까지 완주.
   - 앱 밖 산출물(인쇄 `{emulate:'print'}`·`page.pdf()`, 백엔드 리포트/PDF, 비로그인 공유 링크)도 이 레인이 맡는다.

4. **adversarial 검증 + 완성도 critic → 재투입** — verify 트리거에 걸린 finding(기본·확장 규칙은 LOOP CONTRACT가 SSOT)을 `reviewer`(opus·high·read-only)가 같은 스크린샷으로 반증(거짓양성·과장 제거). 살아남은 것만 채택. 인터랙티브 경로는 Task로 `subagent_type: reviewer` spawn.
   - **메인의 재측정(top-N 직접 재현) — 여정 레인을 돌렸으면 필수.** reviewer는 Bash 없이 스크린샷만 다시 보므로 브라우저를 재현할 수 없다 — "패널이 x=-167에 열린다" 같은 측정 주장은 메인이 critical/high 상위 건을 직접 재현해 숫자로 확인한다. 재현된 것만 CONFIRMED, 못 한 것은 '미재현'.
   - **완성도 critic(reviewer):** 안 본 페이지·뷰포트·역할·빈/초과 상태 1패스 재점검. 추가 체크 — 인터랙션 상태(§1) 미촬영 · 여정 레인(3-B) 생략 · 콜드스타트 빈 스택 미기동. 이 셋이 비면 findings 수와 무관하게 지적한다. critic이 낸 새 결함도 adversarial verify를 한 번 더 통과시켜 채택하고, maxRounds 내면 재캡처·재감사.
   - 실행형 골격: §0 참조.

5. **구조적 처방** — 반복 결함은 페이지별 땜질 대신 공유 프리미티브로: `PageHeader` / `ResponsiveTable`(모바일 reflow) / `EmptyState` / 라벨 맵(SSOT). 프리미티브를 claude.ai/design 디자인시스템에 올려 사용자가 캔버스에서 이어 다듬게 하려면 `DesignSync` — 컴포넌트 단위 증분(통째 교체 금지), `finalize_plan`으로 경로를 잠그고 승인받은 뒤에만 쓰기.

6. **우선순위 findings + (선택) 회귀 baseline** — severity로 정렬 보고. critical/high 시각 결함은 종합 요약이 묻지 못한다. verify/critic 부분 실패로 audit-loop이 `degraded:true`를 반환하면 낙관 결론을 보류한다. 수정 후 재캡처로 회귀 확인, 핵심 화면은 baseline 저장. user-visible 변경이고 디자인 방향이 사용자 판단 사항이면 baseline↔수정 후 스크린샷을 before→after Artifact 보드로 발행(base64 embed, 경로 텍스트만은 결함). 1~2줄 CSS·저위험 변경은 render Read로 충분. 보드도 무손실 규칙 유지 — critical/high를 예쁘게 묻지 않는다.
