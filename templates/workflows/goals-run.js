export const meta = {
  name: 'goals-run',
  description: '자율 척추 — .ksi 원장의 actionable 목표를 evidence-gate로만 소진하는 실행형 루프. "모두 진행" 수동 반복을 구조적으로 없앤다. 종료는 모델 자기선언이 아니라 원장 상태(actionable==0). goals SKILL.md `/goals run`의 실물화(nextgen 1순위).',
  whenToUse: '프로젝트에 .ksi 원장이 있고 여러 목표를 자율로 완결하고 싶을 때. args: {dir(프로젝트 경로 필수), maxGoals(세션당 상한, 기본 6 — 마라톤 방지 세션-경계 stitching), context(공통 맥락)}. red-lane(push·배포·마이그·자금경로·비밀) 차단은 goal 텍스트(제목·수용기준) 정규식 매칭 기반 — 매칭된 goal은 통째로 사람에게 넘긴다. 매칭을 통과한 goal의 구현 중 발생하는 red-lane 행위는 worker 프롬프트 지시 + pre-destructive-guard 훅에 의존한다(코드로 강제되지 않음).',
  phases: [
    { title: 'Run', detail: 'status→start→작업→attempt 루프(위험표면만 즉시 gate) — 원장 소진까지·세션예산까지' },
    { title: 'BatchGate', detail: 'light/standard 목표를 모아 reviewer 1회로 검수(목표 간 상호작용 포함)' },
  ],
}

// ==== RUN CONTRACT (SSOT — goals SKILL.md 산문은 여기를 참조) ====
//  종료 = 원장의 actionable==0(게이트통과/blocked/abandoned) OR 세션예산(maxGoals) 도달. 모델 자기선언 종료 금지.
//  세션-경계 stitching = 마라톤 금지. maxGoals 도달하면 원장에 상태 flush돼 있으므로 깨끗이 suspend,
//    다음 세션이 goal-status.sh brief로 복원해 이어감(원장이 SSOT). 단일 장기루프로 compaction 쌓지 않는다.
//  red-lane 하드스톱 = goal의 title/criteria 자유텍스트가 RED 정규식에 매칭되면 그 goal 자체를 자동 실행 안 함 —
//    needsHuman으로 격리하고 스킵(bypassPermissions 상시 + 되돌리기 게이트[자율성 ①]. worktree primitive는
//    미검증이라 의존하지 않는다 — red는 격리가 아니라 '사람에게 넘김'으로 처리).
//    주의(보장 범위): 이건 goal 텍스트 매칭이지 실행 감시가 아니다 — 매칭을 통과한 goal의 worker가 구현
//    도중 red-lane 행위(push·배포·비밀변경 등)를 하는 것 자체를 이 정규식이 막지는 못한다. 그 경우의 방어선은
//    worker 프롬프트의 "되돌리기 어려우면 needs_human으로 반환" 지시(아래 work agent 프롬프트) + pre-destructive-guard
//    훅뿐 — 둘 다 코드로 강제되는 게이트가 아니라 지시/훅 의존이다.
//  evidence-gate = reviewer가 criteria 대비 증거를 adversarial 검증. refuted면 gate 안 통과 → 그 목표는
//    actionable로 남지만, 같은 목표 attempt N회 실패면 무한루프 방지로 skip(needsHuman).
//  self-report 불신 = worker "완료" 선언이 아니라 reviewer 게이트통과만 completed. ksi-goals가 코드로 강제.
//  게이트 시점 3분기 = 'reviewer를 없애는' 변경이 아니라
//    '언제 부르나'의 재배치다. self-report 불신은 그대로 유지된다(어느 분기도 worker 자기신고로 completed 되지 않음):
//    ① 위험 표면(STRICT_RE 매칭 또는 verification=strict) → **즉시 게이트.** 배치 끝까지 미루면 그 위에 쌓은
//       작업이 통째로 무너진다. ksi-goals.py STRICT_KEYWORDS_BASE를 JS로 미러링(원장 verification 필드가
//       구버전 부재/구조화출력 드롭이어도 텍스트로 판정되게 — 안전한 쪽으로 fail).
//    ② 화면 표면(UI_SURFACE_RE) → **게이트를 아예 안 찍고 needsHuman.** reviewer는 등록된 criteria 대비
//       증거만 본다 — "이게 사용자가 원한 화면인가"는 보기 전엔 criteria에 못 넣으므로 구조적으로 판정 불가다.
//       사람이 실제 화면을 볼 때까지 in_progress로 남긴다(안 본 것을 완료로 봉인하지 않는다 = 무효화·재오픈 비용 제거).
//       ①과 겹치면 ②가 이긴다 — 위험한 화면일수록 사람이 봐야 한다.
//    ③ 나머지(light/standard) → attempt로 증거만 남기고 배치 큐 적재, 루프 종료 후 **reviewer 1회**로 묶어 검수.
//       근거: 실측상 reviewer(opus)가 서브에이전트 최대 소비처였고 대부분이 '기계로 잡히는' 일반 검증이었다
//       (audit-loop.js도 같은 이유로 verify 트리거를 위험 표면으로 좁혔다). 덤으로 개별 게이트가 구조적으로 못 보는 **목표 간 상호작용**(A가 B를 깨뜨렸나)이 잡힌다.
//  배치 게이트 실패 = 청크 전체를 degraded로 기록(pass 없음 — 안전한 쪽). 개별 게이트의 .catch degraded와 동일 원칙.
//  kind = kind:decision(대표자 결정 대기)은 ksi-goals가 actionable에서 제외한다 — 사람이 정할 것을 자율 실행
//    대상으로 삼지 않는다. 대신 decision_pending으로 실려 오고, 종료 로그가 "actionable 0"을 완료로 오독하지
//    않도록 남은 결정 건수를 함께 알린다. RED 정규식(하드스톱)과는 다른 축이다 — RED는 '실행 금지', decision은
//    '애초에 실행할 일이 아님'. RED와 verification:strict는 어휘가 겹치지만 동작이 다르다(RED=스킵, strict=reviewer 필수).
// ====

let A = args || {}
if (typeof A === 'string') {
  try { A = JSON.parse(A) } catch (e) { return { error: 'args가 문자열인데 JSON 파싱 실패 — {dir, maxGoals?, context?} 객체 필요' } }
}
const DIR = A.dir
if (!DIR) return { error: 'args.dir(프로젝트 경로) 필수 — .ksi 원장이 있는 프로젝트 루트' }
const CTX = A.context || ''
const maxGoals = Math.max(1, Math.min(20, A.maxGoals || 6)) // 세션 예산(마라톤 방지). 천장 20.
const maxAttemptsPerGoal = 2 // 같은 목표 반복 실패 시 skip(무한루프 방지)
const G = `python3 ~/.claude/scripts/ksi-goals.py --dir ${JSON.stringify(DIR)}`

// red-lane 어휘 — 되돌리기 어렵거나 외부영향. 목표 title/criteria에 걸리면 자동 실행 금지.
const RED = /push|deploy|배포|출시|release|migrat|마이그|백필|backfill|rollback|롤백|payment|결제|과금|billing|refund|환불|payout|정산|withdraw|출금|mainnet|메인넷|실거래|live[\s_-]?trad|secret|비밀|\.env|credential|rotate|외부\s?전송|prod(uction)?\b/i

// 위험 표면 — 즉시 게이트(배치로 미루지 않는다). ksi-goals.py STRICT_KEYWORDS_BASE의 JS 미러.
// 원장 verification 필드에만 의존하면 구버전 원장(필드 부재)·구조화출력 드롭 시 조용히 배치로 새므로 텍스트로도 판정한다.
const STRICT_RE = /auth|인가|권한|로그인|세션|토큰|비밀|secret|암호|payment|결제|환불|정산|자금|과금|migration|마이그레이션|스키마|삭제|drop|backup|복구|restore|개인정보|PII|테넌트|tenant/i
// 화면 표면 — reviewer가 구조적으로 판정할 수 없는 것(사용자가 봐야 안다). 게이트를 찍지 않고 사람에게 넘긴다.
// 광의어는 의도적으로 정밀화/제외했다(실측 오탐): '페이지'는 페이지네이션(백엔드 API)에, 'form\b'는 transform에,
// '폼'은 플랫폼에 걸린다. '컴포넌트/component'·'스타일'은 백엔드에서도 흔해 통째로 뺐다(스타일시트·CSS만 남김).
// 오탐 비용(완료 가능한 목표가 사람 대기로 남음) < 누락 비용(안 본 화면이 자동 봉인됨)이라 애매하면 화면 쪽으로 두되,
// 명백한 백엔드 어휘까지 끌어오지는 않는다. 매칭된 단어는 로그에 찍어 사용자가 오분류를 바로 알아채게 한다.
const UI_SURFACE_RE = /\bUI\b|\bUX\b|화면|스크린|\bscreen\b|페이지(?!네이션|네이터|네이팅)|레이아웃|\blayout\b|디자인|\bdesign\b|버튼|\bbutton\b|모달|\bmodal\b|팝업|드롭다운|(?<!플랫)폼|\bform\b|반응형|\bresponsive\b|동선|네비게이션|\bnavigation\b|사용성|\busability\b|접근성|\ba11y\b|다크\s?모드|dark\s?mode|스타일시트|\bCSS\b|툴팁|토스트/i

const STATUS_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['done', 'actionable', 'counts'],
  properties: {
    done: { type: 'boolean' },
    // ksi-goals status --json이 내보내는 정지/완료 술어 — additionalProperties:false라 여기 안 나열하면
    // haiku 구조화출력이 드롭한다(그래서 '전부 blocked'를 '완료'와 구분 못 함). 명시적으로 받는다.
    blocked: { type: 'integer' },
    all_completed: { type: 'boolean' },
    quiescent: { type: 'boolean' },
    counts: { type: 'object', additionalProperties: true },
    // 목표 종류별 집계 + 사람 결정 대기(kind=decision). decision은 actionable에서 빠지므로(자율 실행 대상 아님)
    // 여기 실어오지 않으면 "actionable 0 = 완료"로 오독된다 — 종료 로그에서 별도로 알린다.
    counts_by_kind: { type: 'object', additionalProperties: true },
    decision_pending: {
      type: 'array', items: {
        type: 'object', additionalProperties: false, required: ['id', 'title'],
        properties: { id: { type: 'string' }, title: { type: 'string' } },
      },
    },
    actionable: {
      type: 'array', items: {
        // attempt는 required — 크로스세션 loop-guard(baselineAttemptById)의 durability가 이 필드에 걸려 있어
        // structured-output round-trip에서 optional 드롭되면 조용히 세션-only로 강등된다(reviewer 반증 권고 반영).
        // kind·verification은 optional — 구버전 원장(필드 부재)과 섞여 돌 수 있고, 이 루프는 둘로 분기하지 않는다(아래 CONTRACT).
        type: 'object', additionalProperties: false, required: ['id', 'title', 'status', 'attempt'],
        properties: { id: { type: 'string' }, title: { type: 'string' }, status: { type: 'string' }, attempt: { type: 'integer' }, kind: { type: 'string' }, verification: { type: ['string', 'null'] }, criteria: { type: 'array', items: { type: 'string' } }, evidence: { type: ['string', 'null'] } },
      },
    },
  },
}

const WORK_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['goal_id', 'did', 'evidence_ref', 'self_status'],
  properties: {
    goal_id: { type: 'string' },
    did: { type: 'string', description: '실제 수행한 변경 요약' },
    evidence_ref: { type: 'string', description: 'file:line·테스트결과 등 검증 대상 근거(추측 금지)' },
    self_status: { enum: ['attempted', 'blocked', 'needs_human'], description: 'attempted=증거 붙여 게이트로 · blocked=의존성 대기 · needs_human=되돌리기 어려움/판단 필요' },
    block_reason: { type: 'string' },
  },
}

const GATE_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['verdict', 'reason'],
  properties: {
    verdict: { enum: ['pass', 'refuted', 'degraded'], description: 'pass=criteria 충족 실증 · refuted=미충족/환각 · degraded=검증 불완전(rate-limit 등)' },
    reason: { type: 'string', description: '실제 근거 파일을 다시 열어 확인한 결과' },
  },
}

// 배치 게이트 — 여러 목표를 reviewer 1회로 검수하고 목표별 verdict를 돌려받는다.
const BATCH_GATE_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['results'],
  properties: {
    results: {
      type: 'array', items: {
        type: 'object', additionalProperties: false, required: ['goal_id', 'verdict', 'reason'],
        properties: {
          goal_id: { type: 'string' },
          verdict: { enum: ['pass', 'refuted', 'degraded'] },
          reason: { type: 'string', description: '실제 근거 파일을 다시 열어 확인한 결과' },
        },
      },
    },
    // 개별 게이트가 구조적으로 못 보는 축 — 목표들이 서로를 깨뜨렸는지.
    cross_goal: { type: 'string', description: '목표 간 상호작용에서 발견한 문제(없으면 빈 문자열)' },
  },
}

phase('Run')
log(`goals-run: ${DIR} — 세션 예산 ${maxGoals} 목표. 종료=원장 actionable 0 또는 예산 도달(마라톤 방지).`)

// 원장 상태를 기계판독으로 읽는 헬퍼(haiku tier — 단순 CLI 실행+파싱).
const readStatus = () =>
  agent(`${DIR}의 goals 원장 상태를 읽어라. 정확히 이 명령을 Bash로 실행하고 그 JSON을 그대로 반환:\n\`${G} status --json\`\n출력 JSON을 스키마대로 반환하라(가공·추측 금지 — CLI 출력 그대로).`,
    { label: 'status', phase: 'Run', model: 'haiku', schema: STATUS_SCHEMA })

const done = []
const skipped = []       // red-lane·반복실패·blocked
const recordFailures = [] // reviewer는 pass인데 원장이 completed로 봉인 안 됨(기록 실패) — 가짜완료 격리
const batchQueue = []     // light/standard 목표: 구현·증거기록까지 끝내고 루프 종료 후 reviewer 1회로 묶어 검수
let reviewerCalls = 0     // reviewer(opus) 실제 호출 횟수(즉시 게이트 + 배치 청크) — 재배치 효과 측정용
let gateEligible = 0      // 재배치 전이었다면 reviewer를 불렀을 목표 수(=구현이 attempted로 끝난 전부). 비교 baseline.
const attemptsById = {}         // 세션 내 이 goal을 pick한 횟수(디스패치 시점 증가, 결과 무관) — 워크플로 호출마다 리셋되는 in-memory 카운터.
const baselineAttemptById = {}  // repeat-failure 합산 게이팅용: 이 세션에서 goal을 처음 본 시점의 원장 attempt 스냅샷.
let processed = 0
let statusReadFailed = false  // 원장 상태 읽기 실패 — '완료'와 구분(가짜완료 방지)
let carriedStatus = null      // 효율: pass 후 봉인재조회 결과를 다음 반복 top-read로 재사용(무변화 구간 중복 read 제거)

// goal id는 원장 등록 시점에 형식검증되지만(ksi-goals _check_id), 오래된 원장·오염 대비 방어적 인용.
// 정상 id(^[A-Za-z][A-Za-z0-9_.-]{0,63}$)는 그대로, 이례적이면 single-quote로 감싸 shell 보간을 무력화.
const qid = (id) => (/^[A-Za-z][A-Za-z0-9_.-]{0,63}$/.test(String(id)) ? String(id) : `'${String(id).replace(/'/g, "'\\''")}'`)
// 자유텍스트 인자(evidence_ref·reason)를 bash에 안전하게 single-quote — JSON.stringify(이중따옴표)는 bash에서
// $(...)·백틱을 여전히 평가해 워커 산출물이 명령치환 페이로드를 실으면 실행될 수 있다. single-quote는 그 전부를 리터럴화.
const shq = (s) => `'${String(s == null ? '' : s).replace(/'/g, "'\\''")}'`

while (processed < maxGoals) {
  // .catch(null): agent가 throw(null 반환이 아니라)해도 워크플로 abort 대신 statusReadFailed→degraded 경로로.
  // carriedStatus: 직전 pass의 봉인재조회 결과가 있으면(원장 무변화) 그것을 재사용해 중복 top-read 스킵(효율).
  const st = carriedStatus || await readStatus().catch(() => null)
  carriedStatus = null
  // 상태 읽기 실패(null)를 '완료(actionable 0)'와 섞지 않는다 — 예전엔 CLI/파싱/agent 실패가 전부
  // '완료' 경로로 빠져 미완 원장을 완료로 오해했다(green≠작동). 실패는 DEGRADED로 안전 중단.
  if (!st) {
    statusReadFailed = true
    log(`⚠ 원장 상태 읽기 실패(null 반환) — DEGRADED, 안전 중단(완료로 오해 금지). goal-status로 수동 확인 필요.`)
    break
  }
  if (st.done || !(st.actionable || []).length) {
    // '완료'와 '멈췄으나 blocked 잔존(사람 대기)'을 구분해 로그 — 전부 blocked를 완료로 오해하지 않게(술어 소비).
    if (st.quiescent || (st.blocked && !st.all_completed)) {
      log(`원장 actionable 0 — 단, blocked ${st.blocked || '?'}건이 남아 '완료'가 아니라 사람 대기(quiescent). goal-status로 확인.`)
    } else {
      log(`원장 actionable 0 — 완료(원장 상태 기준, 모델 선언 아님)${st.all_completed ? ' · 전부 completed' : ''}.`)
    }
    break
  }
  // 아직 skip 안 했고 배치 큐에도 안 들어간 것 중 다음.
  // batchQueue 제외가 없으면 배치 대기 목표(원장상 여전히 actionable)를 매 반복 다시 pick해 무한 재구현한다.
  const next = st.actionable.find((g) => !skipped.some((s) => s.id === g.id) && !batchQueue.some((b) => b.id === g.id))
  if (!next) { log('남은 actionable이 전부 처리됨(배치 검수 대기 또는 skip) — 루프 종료.'); break }

  // red-lane 하드스톱 — 자동 실행 금지.
  const redHit = RED.test(next.title) || (next.criteria || []).some((c) => RED.test(c))
  if (redHit) {
    skipped.push({ id: next.id, title: next.title, why: 'red-lane(되돌리기 어려움/외부영향) — 자동 실행 안 함, 사람 확인 필요' })
    log(`⛔ red-lane 스킵: [${next.id}] ${next.title} — 사람에게 넘김(push/배포/마이그/자금/비밀류).`)
    continue
  }

  // repeat-failure skip — 세션 내 시도(attemptsById)만으로는 워크플로 호출마다(=새 세션마다) 카운터가 0으로
  // 리셋돼, 여러 세션에 걸쳐 반복 실패한 goal이 매번 새 재시도 예산을 리필받는다(무한루프 방지가 세션 경계에서
  // 무력화). next.attempt(ksi-goals가 gate --verdict refuted마다 +1, 신규 goal은 1부터 시작 — block/degraded/
  // needs_human은 증가 안 시킴)는 원장에 영속돼 세션을 넘어 살아남으므로 이걸 세션 카운터와 합산한다.
  // baselineAttemptById는 "이 세션에서 이 goal을 처음 본 시점"의 next.attempt를 얼어붙은 스냅샷으로 고정한다 —
  // 그래야 이번 세션 중 발생한 refuted(=next.attempt가 실시간으로 올라감)를 attemptsById와 이중집계하지 않는다.
  if (!(next.id in baselineAttemptById)) baselineAttemptById[next.id] = next.attempt || 1
  const priorSessionFailures = Math.max(0, baselineAttemptById[next.id] - 1) // 이전 세션(들)에서 이미 소진된 시도 수(신규 goal=0)
  attemptsById[next.id] = (attemptsById[next.id] || 0) + 1
  const totalAttempts = priorSessionFailures + attemptsById[next.id]
  if (totalAttempts > maxAttemptsPerGoal) {
    skipped.push({
      id: next.id, title: next.title,
      why: `시도예산 소진(세션내 ${attemptsById[next.id]}회 + 이전세션누적 ${priorSessionFailures}회 = 총 ${totalAttempts}/${maxAttemptsPerGoal}) — 무한루프 방지 skip, 사람 처리`,
    })
    log(`↷ 반복실패 스킵(세션경계 합산): [${next.id}] ${next.title} — 세션내 ${attemptsById[next.id]} + 이전세션 ${priorSessionFailures} = ${totalAttempts}/${maxAttemptsPerGoal}`)
    continue
  }

  processed++
  log(`▶ [${next.id}] ${next.title} (attempt 세션내 ${attemptsById[next.id]}·누적 ${totalAttempts}/${maxAttemptsPerGoal})`)

  // 작업 — worker tier(sonnet). start → 실제 구현 → attempt --evidence.
  const work = await agent(`${CTX}

## goals-run 작업 — 프로젝트 ${DIR}, 목표 [${next.id}] "${next.title}"
완료기준: ${(next.criteria || []).join(' / ') || '(명시 없음 — title 기준 합리적 판단)'}

임무: 이 목표를 실제로 구현한다(코드 변경·테스트). 규율:
- 먼저 Bash로 \`${G} start --id ${qid(next.id)}\`(이미 in_progress면 무해 — 멱등).
- 실제 코드를 읽고 변경하라(Edit/Write). "green≠작동" — 테스트·타입체크를 실제로 돌려 통과를 확인하고, 픽스처가 실제 흐름을 우회하지 않는지 본다.
- **되돌리기 어렵거나 외부영향(push·배포·DB 마이그레이션 실행·비밀변경·외부전송·자금경로)이면 그 부분은 하지 말고 self_status='needs_human'으로 반환**(이 루프는 그런 걸 자동 실행하지 않는다).
- 끝나면 \`${G} attempt --id ${qid(next.id)} --evidence "<검증한 실제 근거>"\`로 증거를 원장에 기록(이게 있어야 게이트가 돈다).
- evidence_ref엔 reviewer가 재확인할 수 있는 구체 근거(file:line·테스트 출력)를 담아라 — 추측·자기선언 금지.`,
    { label: `work:${next.id}`, phase: 'Run', model: 'sonnet', effort: 'high', schema: WORK_SCHEMA })
  // effort:'high' 명시 — 미지정이면 ultracode 세션의 xhigh를 상속해 구현 워커가 사고 비용을 과잉 지불(P1' 2축 배치).

  if (!work || work.self_status === 'needs_human') {
    skipped.push({ id: next.id, title: next.title, why: (work && work.block_reason) || 'worker가 needs_human 판정(되돌리기 어려움/판단 필요)' })
    log(`⛔ worker→needs_human: [${next.id}] — 사람에게 넘김.`)
    // 원장은 in_progress로 남음(다음 세션 복원). block 처리는 사람 몫.
    continue
  }
  if (work.self_status === 'blocked') {
    // 기록 실패를 묵살하지 않는다 — 원장은 in_progress인데 반환값은 blocked인 불일치를 가시화(durable state 원칙).
    const blockOut = await agent(`Bash로 실행: \`${G} block --id ${qid(next.id)} --reason ${shq((work.block_reason || 'dependency').slice(0, 120))}\`\n출력을 그대로 반환.`, { label: `block:${next.id}`, phase: 'Run', model: 'haiku' }).catch((e) => `__block_record_error__: ${(e && e.message) || e}`)
    const blockRecorded = !String(blockOut).includes('__block_record_error__')
    if (!blockRecorded) log(`⚠ [${next.id}] block 원장 기록 실패 — 원장은 in_progress로 남음(반환값과 불일치). 수동 확인 필요.`)
    skipped.push({ id: next.id, title: next.title, why: 'blocked: ' + (work.block_reason || '') + (blockRecorded ? '' : ' (⚠원장 기록 실패)') })
    continue
  }

  // ==== 게이트 시점 3분기(RUN CONTRACT 참조) — 판정 텍스트는 title+criteria ====
  gateEligible++ // 재배치 전이라면 여기서 무조건 reviewer가 1회 돌았다(비교 baseline).
  const goalText = `${next.title} ${(next.criteria || []).join(' ')}`
  const isUI = UI_SURFACE_RE.test(goalText)
  const isStrict = next.verification === 'strict' || STRICT_RE.test(goalText)

  // ② 화면 표면 — 게이트를 찍지 않는다. reviewer는 등록된 criteria 대비 증거만 보므로 "사용자가 원한 화면인가"를
  //    구조적으로 판정할 수 없다. 구현물은 남기고 원장은 in_progress로 둬 사람이 실제 화면을 보고 확정하게 한다.
  //    (①과 겹쳐도 여기가 이긴다 — 위험한 화면일수록 사람이 봐야 한다.)
  if (isUI) {
    skipped.push({
      id: next.id, title: next.title,
      why: '화면 표면 — 구현은 끝났고 증거도 기록됨. 사용자가 실제 화면을 확인해야 완료(자동 봉인 안 함, 원장 in_progress 유지)',
    })
    // 매칭 단어를 함께 찍는다 — 오분류(백엔드 목표가 화면으로 잡힘)를 사용자가 즉시 알아채고 제목을 고칠 수 있게.
    log(`👁 [${next.id}] 화면 확인 대기 — 구현 완료·게이트 미실행. 실제 화면을 보고 확정 필요. (매칭: "${(goalText.match(UI_SURFACE_RE) || [''])[0]}")`)
    continue
  }

  // ③ light/standard — 증거는 attempt로 이미 기록됐다. 배치 큐에 넣고 루프 끝에서 reviewer 1회로 묶어 검수.
  if (!isStrict) {
    batchQueue.push({ id: next.id, title: next.title, criteria: next.criteria || [], did: work.did, evidence_ref: work.evidence_ref })
    log(`⋯ [${next.id}] 배치 검수 대기(큐 ${batchQueue.length}) — 루프 끝에서 reviewer 1회로 묶어 검증.`)
    continue
  }

  // ① 위험 표면 — 즉시 게이트. reviewer(opus read-only)가 criteria 대비 증거를 adversarial 검증.
  reviewerCalls++
  const gate = await agent(`${CTX}

## goals-run evidence-gate — 목표 [${next.id}] "${next.title}"
완료기준: ${(next.criteria || []).join(' / ') || '(title 기준)'}
worker가 한 것: ${work.did}
worker가 댄 증거: ${work.evidence_ref}

임무: 이 목표가 **실제로** 완료기준을 충족했는지 회의적으로 검증하라. worker의 self-report·증거 인용을 믿지 말고 **실제 파일을 다시 열어 확인**한다. criteria가 코드/테스트로 실증되면 pass, 미충족·환각·픽스처 우회면 refuted, 검증이 rate-limit 등으로 불완전하면 degraded. 기본자세는 의심.`,
    { label: `gate:${next.id}`, phase: 'Run', agentType: 'reviewer', schema: GATE_SCHEMA })
    // reviewer 호출이 throw(rate-limit·context 오류)해도 워크플로를 abort하지 않고 degraded로 격리:
    // 이전엔 무catch라 throw 시 gate --verdict degraded 기록 없이 전체 중단 → durable loop 회복성 파손.
    .catch((e) => ({ verdict: 'degraded', reason: `reviewer 호출 실패: ${String((e && e.message) || e).slice(0, 120)}` }))

  const verdict = (gate && gate.verdict) || 'degraded'
  // 게이트 결과를 원장에 기록(pass만 completed로 봉인 — 코드가 강제). --note에 reviewer 사유 포함:
  // refuted/degraded 후 다음 세션이 "왜 실패했나"를 원장에서 복원할 수 있게(ledger.jsonl에 note가 남는다).
  const recordOut = await agent(`Bash로 아래를 그대로 실행하고 표준출력을 **가공 없이 그대로** 반환하라(성공 시 "completed" 문구·실패 시 에러 메시지):\n\`${G} gate --id ${qid(next.id)} --verdict ${verdict} --reviewer reviewer-opus --evidence-ref ${shq((work.evidence_ref || '').slice(0, 160))} --note ${shq(((gate && gate.reason) || '').slice(0, 200))}\``,
    { label: `record:${next.id}`, phase: 'Run', model: 'haiku' }).catch((e) => `__record_error__: ${(e && e.message) || e}`)

  if (verdict === 'pass') {
    // 가짜완료 방지(green≠작동): reviewer가 pass여도 원장이 실제 completed로 봉인됐는지 **재조회로 확인** 후에만 done.
    // 예전엔 기록 실패(.catch로 삼킴)를 무시하고 done.push해, 원장은 in_progress인데 워크플로는 completed를 반환했다.
    // pass가 봉인되면 그 목표는 completed로 빠져 actionable에서 사라진다 → 재조회 actionable 부재로 봉인 확인.
    const after = await readStatus().catch(() => null)
    const stillActionable = !!(after && (after.actionable || []).some((g) => g.id === next.id))
    if (after && !stillActionable) {
      done.push({ id: next.id, title: next.title })
      log(`✓ [${next.id}] 게이트 통과 → 원장 completed 봉인 확인.`)
      carriedStatus = after  // 무변화 구간 — 다음 반복 top-read로 재사용(중복 원장 read 제거)
    } else {
      recordFailures.push({
        id: next.id, title: next.title,
        why: after ? '기록 후에도 원장이 completed 아님(gate CLI 실패 추정 — 예: evidence 누락)' : '기록 후 원장 재조회 실패',
        record_out: String(recordOut).slice(0, 200),
      })
      log(`⚠ [${next.id}] reviewer pass였으나 원장 봉인 미확인 → DEGRADED(가짜완료 방지, done 아님). 기록출력: ${String(recordOut).slice(0, 120)}`)
    }
  } else {
    log(`✗ [${next.id}] ${verdict} — ${(gate && gate.reason || '').slice(0, 100)} (원장에 남아 재시도/사람)`)
    // refuted/degraded면 다음 루프에서 같은 목표 재선택 → attempt 카운터가 무한루프 방지.
  }
}

// ==== 배치 게이트 — light/standard 목표를 reviewer 1회(청크당)로 묶어 검수 ====
// 개별 게이트 대비 opus 호출 N → ceil(N/BATCH_MAX). 덤: 개별 게이트가 구조적으로 못 보는 목표 간 상호작용.
const BATCH_MAX = 8 // reviewer 한 번의 context가 무한정 커지지 않게(초과분은 나눠 호출)
if (batchQueue.length) {
  phase('BatchGate')
  log(`배치 검수 ${batchQueue.length}건 → reviewer ${Math.ceil(batchQueue.length / BATCH_MAX)}회 호출(목표마다 걸었다면 ${batchQueue.length}회).`)
}
for (let i = 0; i < batchQueue.length; i += BATCH_MAX) {
  const chunk = batchQueue.slice(i, i + BATCH_MAX)
  reviewerCalls++
  const batch = await agent(`${CTX}

## goals-run 배치 검수 — 프로젝트 ${DIR}, 목표 ${chunk.length}건
${chunk.map((c, n) => `
### ${n + 1}. [${c.id}] ${c.title}
완료기준: ${(c.criteria || []).join(' / ') || '(title 기준)'}
worker가 한 것: ${c.did}
worker가 댄 증거: ${c.evidence_ref}`).join('\n')}

임무: 위 목표들이 **각각 실제로** 완료기준을 충족했는지 회의적으로 검증하라. worker의 self-report·증거 인용을 믿지 말고 **실제 파일을 다시 열어 확인**한다. 목표별로 verdict를 낸다 — criteria가 코드/테스트로 실증되면 pass, 미충족·환각·픽스처 우회면 refuted, 검증이 불완전하면 degraded. 기본자세는 의심.
**그리고 이 배치에서만 볼 수 있는 것을 본다 — 목표들이 서로를 깨뜨렸는가.** A의 변경이 B의 완료기준을 무효화했는지, 같은 파일을 상충되게 고쳤는지, 뒤 목표가 앞 목표의 검증을 우회하게 만들었는지. 발견하면 cross_goal에 적고 영향받은 목표는 refuted로 내린다.
results에는 위 ${chunk.length}건의 goal_id를 빠짐없이 담아라.`,
    { label: `batch-gate:${Math.floor(i / BATCH_MAX) + 1}`, phase: 'BatchGate', agentType: 'reviewer', schema: BATCH_GATE_SCHEMA })
    // 배치 호출 실패 = 청크 전체 degraded(pass 없음 — 안전한 쪽). 개별 게이트 .catch와 동일 원칙.
    .catch((e) => ({
      results: chunk.map((c) => ({ goal_id: c.id, verdict: 'degraded', reason: `배치 reviewer 호출 실패: ${String((e && e.message) || e).slice(0, 120)}` })),
      cross_goal: '',
    }))

  if (batch && batch.cross_goal) log(`⚠ 목표 간 상호작용: ${String(batch.cross_goal).slice(0, 300)}`)

  const byId = {}
  for (const r of (batch && batch.results) || []) byId[r.goal_id] = r

  const passed = []
  for (const c of chunk) {
    // reviewer가 결과를 빠뜨린 목표를 pass로 오해하지 않는다 — 누락=미검증=degraded(가짜완료 방지).
    const r = byId[c.id] || { verdict: 'degraded', reason: 'reviewer가 이 목표의 verdict를 반환하지 않음(미검증)' }
    const recordOut = await agent(`Bash로 아래를 그대로 실행하고 표준출력을 **가공 없이 그대로** 반환하라(성공 시 "completed" 문구·실패 시 에러 메시지):\n\`${G} gate --id ${qid(c.id)} --verdict ${r.verdict} --reviewer reviewer-opus-batch --evidence-ref ${shq((c.evidence_ref || '').slice(0, 160))} --note ${shq(String(r.reason || '').slice(0, 200))}\``,
      { label: `record:${c.id}`, phase: 'BatchGate', model: 'haiku' }).catch((e) => `__record_error__: ${(e && e.message) || e}`)
    if (r.verdict === 'pass') passed.push({ c, recordOut })
    else log(`✗ [${c.id}] ${r.verdict} — ${String(r.reason || '').slice(0, 100)} (원장에 남아 재시도/사람)`)
  }

  // 봉인 확인(green≠작동) — 개별 게이트는 goal마다 재조회했지만 배치는 청크당 1회로 묶는다.
  if (passed.length) {
    const after = await readStatus().catch(() => null)
    for (const { c, recordOut } of passed) {
      const stillActionable = !!(after && (after.actionable || []).some((g) => g.id === c.id))
      if (after && !stillActionable) {
        done.push({ id: c.id, title: c.title })
        log(`✓ [${c.id}] 배치 게이트 통과 → 원장 completed 봉인 확인.`)
      } else {
        recordFailures.push({
          id: c.id, title: c.title,
          why: after ? '기록 후에도 원장이 completed 아님(gate CLI 실패 추정 — 예: evidence 누락)' : '기록 후 원장 재조회 실패',
          record_out: String(recordOut).slice(0, 200),
        })
        log(`⚠ [${c.id}] reviewer pass였으나 원장 봉인 미확인 → DEGRADED(가짜완료 방지, done 아님).`)
      }
    }
  }
}

const fin = await readStatus().catch(() => null)
if (!fin) statusReadFailed = true // 최종 read 실패도 DEGRADED에 반영 — remaining='?'만 남기고 낙관 반환하지 않게
const remaining = fin ? (fin.actionable || []).length : '?'
if (processed >= maxGoals && remaining && remaining !== 0) {
  log(`⏸ 세션 예산(${maxGoals}) 도달 — 남은 actionable ${remaining}개는 다음 세션이 이어간다(원장이 SSOT, 마라톤 방지 suspend).`)
}
if (skipped.length) log(`⚠ 사람 처리 필요 ${skipped.length}건(red-lane/반복실패/needs_human/화면 확인 대기) — 아래 목록.`)
// kind:decision은 actionable에서 빠져 있다 — 알리지 않으면 "actionable 0"이 완료로 읽힌다(대표자 결정이 묻히던 실패 모드).
const decisions = fin ? (fin.decision_pending || []) : []
if (decisions.length) log(`◆ 대표자 결정 대기 ${decisions.length}건 — 자율 실행 대상이 아니라 사람이 정해야 진행된다: ${decisions.map((d) => d.title).join(' · ').slice(0, 200)}`)
if (recordFailures.length) log(`⚠ DEGRADED: ${recordFailures.length}건은 reviewer pass였으나 원장 봉인 미확인(가짜완료 방지 — done 아님). 수동 확인 필요.`)
if (statusReadFailed) log(`⚠ DEGRADED: 원장 상태 읽기 실패로 조기 중단 — 완료 판단 보류.`)

return {
  project: DIR,
  completed_this_session: done,
  needs_human: skipped,
  record_failures: recordFailures, // reviewer pass인데 원장이 completed로 봉인 안 된 건(가짜완료 격리)
  decision_pending: decisions, // 대표자가 정해야 진행되는 건 — actionable에 안 세지만 '완료'도 아니다
  remaining_actionable: remaining,
  suspended: processed >= maxGoals && remaining !== 0,
  // reviewer(opus) 실제 호출 횟수 vs 재배치 전이었다면 불렸을 횟수(구현이 attempted로 끝난 목표 = 목표당 1회).
  reviewer_calls: reviewerCalls,
  reviewer_calls_before_rebatch: gateEligible,
  // green≠작동: 기록 실패·상태읽기 실패가 있으면 낙관 top-line 보류(위임자가 완료로 relay 금지).
  degraded: recordFailures.length > 0 || statusReadFailed,
  status_read_failed: statusReadFailed,
  note: '완료=reviewer 게이트통과 AND 원장 completed 봉인 확인만(green≠작동). 게이트 시점만 3분기(위험표면=즉시 · 화면=사람이 볼 때까지 봉인 안 함 · 나머지=배치 1회) — 자기신고로 completed 되는 경로는 없다. red-lane·되돌리기 어려운 건 자동 실행 안 하고 needs_human으로 격리. 다음 세션은 goal-status.sh가 복원.',
}
