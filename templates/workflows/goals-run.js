export const meta = {
  name: 'goals-run',
  description: '자율 척추 — .ksi 원장의 actionable 목표를 evidence-gate로만 소진하는 실행형 루프. "모두 진행" 수동 반복을 구조적으로 없앤다. 종료는 모델 자기선언이 아니라 원장 상태(actionable==0). goals SKILL.md `/goals run`의 실물화(nextgen 1순위).',
  whenToUse: '프로젝트에 .ksi 원장이 있고 여러 목표를 자율로 완결하고 싶을 때. args: {dir(프로젝트 경로 필수), maxGoals(세션당 상한, 기본 6 — 마라톤 방지 세션-경계 stitching), context(공통 맥락)}. red-lane(push·배포·마이그·자금경로·비밀) 차단은 goal 텍스트(제목·수용기준) 정규식 매칭 기반 — 매칭된 goal은 통째로 사람에게 넘긴다. 매칭을 통과한 goal의 구현 중 발생하는 red-lane 행위는 worker 프롬프트 지시 + pre-destructive-guard 훅에 의존한다(코드로 강제되지 않음).',
  phases: [
    { title: 'Run', detail: 'status→start→작업→attempt→reviewer gate 루프(원장 소진까지·세션예산까지)' },
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
const RED = /push|deploy|배포|출시|release|migrat|마이그|백필|backfill|rollback|롤백|payment|결제|과금|billing|refund|환불|payout|정산|withdraw|출금|secret|비밀|\.env|credential|rotate|외부\s?전송|prod(uction)?\b/i

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
    actionable: {
      type: 'array', items: {
        // attempt는 required — 크로스세션 loop-guard(baselineAttemptById)의 durability가 이 필드에 걸려 있어
        // structured-output round-trip에서 optional 드롭되면 조용히 세션-only로 강등된다(reviewer 반증 권고 반영).
        type: 'object', additionalProperties: false, required: ['id', 'title', 'status', 'attempt'],
        properties: { id: { type: 'string' }, title: { type: 'string' }, status: { type: 'string' }, attempt: { type: 'integer' }, criteria: { type: 'array', items: { type: 'string' } }, evidence: { type: ['string', 'null'] } },
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

phase('Run')
log(`goals-run: ${DIR} — 세션 예산 ${maxGoals} 목표. 종료=원장 actionable 0 또는 예산 도달(마라톤 방지).`)

// 원장 상태를 기계판독으로 읽는 헬퍼(haiku tier — 단순 CLI 실행+파싱).
const readStatus = () =>
  agent(`${DIR}의 goals 원장 상태를 읽어라. 정확히 이 명령을 Bash로 실행하고 그 JSON을 그대로 반환:\n\`${G} status --json\`\n출력 JSON을 스키마대로 반환하라(가공·추측 금지 — CLI 출력 그대로).`,
    { label: 'status', phase: 'Run', model: 'haiku', schema: STATUS_SCHEMA })

const done = []
const skipped = []       // red-lane·반복실패·blocked
const recordFailures = [] // reviewer는 pass인데 원장이 completed로 봉인 안 됨(기록 실패) — 가짜완료 격리
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
  // carriedStatus: 직전 pass의 봉인재조회 결과가 있으면(원장 무변화) 그것을 재사용해 중복 top-read 스킵(효율 0.8.3).
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
  // 아직 skip 안 한 것 중 다음
  const next = st.actionable.find((g) => !skipped.some((s) => s.id === g.id))
  if (!next) { log('남은 actionable이 전부 skip 대상(red-lane/반복실패) — 사람 처리 필요, 종료.'); break }

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

  // evidence-gate — reviewer(opus read-only)가 criteria 대비 증거를 adversarial 검증.
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

const fin = await readStatus().catch(() => null)
if (!fin) statusReadFailed = true // 최종 read 실패도 DEGRADED에 반영 — remaining='?'만 남기고 낙관 반환하지 않게
const remaining = fin ? (fin.actionable || []).length : '?'
if (processed >= maxGoals && remaining && remaining !== 0) {
  log(`⏸ 세션 예산(${maxGoals}) 도달 — 남은 actionable ${remaining}개는 다음 세션이 이어간다(원장이 SSOT, 마라톤 방지 suspend).`)
}
if (skipped.length) log(`⚠ 사람 처리 필요 ${skipped.length}건(red-lane/반복실패/needs_human) — 아래 목록.`)
if (recordFailures.length) log(`⚠ DEGRADED: ${recordFailures.length}건은 reviewer pass였으나 원장 봉인 미확인(가짜완료 방지 — done 아님). 수동 확인 필요.`)
if (statusReadFailed) log(`⚠ DEGRADED: 원장 상태 읽기 실패로 조기 중단 — 완료 판단 보류.`)

return {
  project: DIR,
  completed_this_session: done,
  needs_human: skipped,
  record_failures: recordFailures, // reviewer pass인데 원장이 completed로 봉인 안 된 건(가짜완료 격리)
  remaining_actionable: remaining,
  suspended: processed >= maxGoals && remaining !== 0,
  // green≠작동: 기록 실패·상태읽기 실패가 있으면 낙관 top-line 보류(위임자가 완료로 relay 금지).
  degraded: recordFailures.length > 0 || statusReadFailed,
  status_read_failed: statusReadFailed,
  note: '완료=reviewer 게이트통과 AND 원장 completed 봉인 확인만(green≠작동). red-lane·되돌리기 어려운 건 자동 실행 안 하고 needs_human으로 격리. 다음 세션은 goal-status.sh가 복원.',
}
