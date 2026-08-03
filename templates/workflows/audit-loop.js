export const meta = {
  name: 'audit-loop',
  description: '재사용 감사 루프 — analyze fan-out → adversarial verify → critic(검증 후 재투입) → 수렴. codebase-audit/ui-audit §0.5의 실행형 골격.',
  whenToUse: '병렬 감사가 필요할 때 매번 pipeline을 재작성하지 말고 units(키+프롬프트)와 dial만 args로 넘긴다.',
}

// ==== LOOP CONTRACT (SSOT — codebase-audit/ui-audit 스킬 산문은 의미를 재명세하지 말고 여기를 참조) ====
//  survivor   = verdict ≠ 'refuted' 인 finding (verify 실패=error 는 confirmed 아님 → degraded 버킷).
//  verify 트리거 = verifySeverities(기본 ['critical']) + severity=high 이면서 위험 표면(auth·권한·자금경로·
//                 상태전이·마이그레이션·시크릿)인 finding. 미트리거 = 'unverified'(정책 skip, 실패 아님).
//                 일반 high는 메인이 직접 판정한다 — reviewer 호출량 축소(0.9.16).
//  verify 실패(throw/rate-limit) = 'error' → degraded[]에 격리, counts에 confirmed로 세지 않음, return.degraded=true.
//  analyze 실패 = 해당 unit은 coveredUnits에서 제외하고 units_analyze_failed[]에 격리(위장 커버리지 금지) → return.degraded=true.
//  critic 호출 실패(throw) = critic_failed=true(완성도 재점검 미수행) → return.degraded=true.
//  reviewer agentType 폴백 = agentType 미등록/미상 오류만 opus model로 폴백(counts.reviewer_fallbacks). 일시적 오류(rate-limit/timeout)는 폴백 대신 DEGRADED로 격리(rate-limit 악화 방지).
//  return findings = verified+unverified union(하위호환). 'reviewer 통과'만 원하면 verified_findings(=confirmed/adjust). unverified_findings=verify 미트리거(정책 skip, 미검증).
//  정지       = critic 무소득 또는 round == maxRounds(기본 2 · 천장 4, dial). 남은 미탐색 단위 = units_deferred.
//  tier       = analyze:sonnet(dial, unit별 model override 가능) · verify/critic:reviewer(opus·xhigh·read-only, 부재 시 opus 폴백).
// ====

// ---- args (dial) ----
// units: [{key, prompt, model?}]  필수 — 단위별 분석 지시(출력 지시는 불필요, 스키마가 강제).
//   model은 unit별 analyzeModel override(alias만 — 풀 ID 금지), 미지정시 analyzeModel 사용.
// context: 모든 에이전트 프롬프트 앞에 붙는 공통 맥락(제품·페르소나·경로·design-side spec). 강력 권장.
// analyzeModel='sonnet'  (alias만 — 풀 ID 금지) · analyzeEffort='high'(기본 — 세션 xhigh 상속 차단, P1' 2축 배치)
// reviewerAgent='reviewer' (기본) — verify·critic을 reviewer 서브에이전트(opus·xhigh·read-only)로 라우팅: frontmatter가
//   effort·read-only를 고정해 비-ultracode 세션에서도 xhigh로 검증. false면 model 기반(verifyModel/criticModel)으로 폴백.
// verifyModel='opus' | criticModel='opus' — reviewerAgent=false일 때만 쓰는 폴백 모델.
// maxRounds — critic 재투입 포함 상한: 기본 2, 천장 4(스킬 문서의 '상한 2'는 기본값 서술). verifySeverities=['critical'](기본) — verify 트리거(dial). 위험 표면 high는 자동 추가.
// critic=true — false면 critic 생략(작은 감사).
// args가 JSON-encoded 문자열로 도착하는 호출 경로 방어(스모크 런에서 실측된 함정)
let A = args || {}
if (typeof A === 'string') {
  try { A = JSON.parse(A) } catch (e) { return { error: 'args가 문자열인데 JSON 파싱 실패 — 객체로 넘기거나 유효한 JSON으로' } }
}
const units0 = Array.isArray(A.units) ? A.units.filter((u) => u && u.key && u.prompt) : []
if (!units0.length) return { error: 'args.units가 비어 있음 — [{key, prompt}] 필요' }
const CTX = A.context || ''
const analyzeModel = A.analyzeModel || 'sonnet'
// verify/critic 기본을 opus 밑으로(예: Sonnet 5) 내리지 말 것 — producer(worker=sonnet)와 같은 weight면
// blind spot이 correlated라 error-decorrelation이 사라진다(cross-model opus skeptic이라야 반증이 산다).
// 게다가 Sonnet 5는 '보수적 지시 literal 추종'(코드리뷰/verify recall 손실) 패턴이 VERDICT의 '기본 태도는 의심'과 겹친다.
const verifyModel = A.verifyModel || 'opus'
const criticModel = A.criticModel || 'opus'
const maxRounds = Math.max(1, Math.min(4, A.maxRounds || 2))
// verify 트리거(0.9.16): 기본을 critical/high → **critical + 위험 표면 high**로 좁혔다.
// 근거(실측): reviewer(opus·xhigh)가 서브에이전트 세션 1,634+로 단일 최대 소비처였고, 그 대부분이
// '일반 high' verify였다. 일반 high는 메인(opus·xhigh, full context)이 직접 판정하는 편이 싸고 정확하다.
// 위험 표면(auth·권한·자금경로·상태전이·마이그레이션·시크릿)의 high는 틀리면 비싸므로 계속 반증한다.
// A.verifySeverities를 명시하면 그 값이 우선(override 경로 무손상) — 예전 동작은 ['critical','high'].
const verifySev = Array.isArray(A.verifySeverities) ? A.verifySeverities : ['critical']
const RISK_SURFACE_RE = /auth|인증|권한|permission|rbac|role|token|session|secret|credential|tenant|isolation|결제|payment|billing|refund|환불|자금|정산|payout|멱등|idempoten|마이그레이션|migration|schema|상태\s*전이|state\s*machine|transition/i
const isRiskSurface = (f) => RISK_SURFACE_RE.test(`${f.title || ''} ${f.where || ''} ${f.category || ''} ${f.impact || ''}`)
// critical은 무조건 · high는 위험 표면일 때만 · (verifySev에 high를 명시했다면 첫 절이 이미 커버)
const shouldVerify = (f) => verifySev.includes(f.severity) || (f.severity === 'high' && isRiskSurface(f))
// critic auto-scale(0.8.3): 소규모 감사(≤2 유닛)엔 critic 기본 off — caller가 opt-out을 기억 안 해도 opus critic 낭비 없음.
// 명시 지정(A.critic)은 항상 존중. 스킬 §0의 '소규모=critic:false' 권고를 워크플로에 baked-in.
const useCritic = A.critic === undefined ? units0.length > 2 : A.critic !== false
// batchSize: 한 라운드의 analyze fan-out을 N개 단위씩 끊어 실행(청크 사이 barrier) — 동시
// 실행 에이전트 수를 줄여 API rate-limit(TPM/ITPM) cascade 실패를 회피. 기본=전체(끊지 않음, 종전 동작).
let batchSize = A.batchSize
if (!(Number.isFinite(batchSize) && batchSize >= 1)) {
  if (batchSize !== undefined) log(`⚠ batchSize 값 비정상(${JSON.stringify(A.batchSize)}) → units0.length(${units0.length})로 폴백`)
  batchSize = units0.length
}
// verify/critic = reviewer tier(opus·xhigh·read-only). reviewerAgent=false면 처음부터 model 기반.
const reviewerAgent = A.reviewerAgent === undefined ? 'reviewer' : A.reviewerAgent
// reviewer로 실행하되 미설치·미해석(agentType 미등록)이면 model 기반 opus로 폴백 —
// verify가 silent no-op(미검증 finding을 그냥 confirmed)으로 무너지지 않게(가짜 green 방지).
let reviewerFallbacks = 0
let reviewerFallbackWarned = false
// 오류 분류(2026-07-18): 예전엔 agentType 실패 시 '무조건' opus 모델로 폴백해, rate-limit/timeout류
// 일시적 오류에도 같은 비싼 opus를 즉시 재호출 → rate-limit을 되레 악화시켰다. 일시적 오류는 폴백하지 말고
// rethrow해 상위(verifyOne/critic)가 DEGRADED로 격리하게 하고, agentType 미등록/미상 오류만 opus로 폴백
// (verify가 silent no-op으로 무너져 미검증 finding을 confirmed로 흘리는 것 방지). read-only/effort 고정 상실은 폴백의 알려진 대가.
const TRANSIENT_RE = /rate.?limit|429|overloaded|529|503|timeout|timed out|too many requests|quota|session (?:limit|token)|context (?:window|length)|network|ECONN|ETIMEDOUT/i
const isTransientErr = (e) => {
  // 구조화 필드 우선(runtime이 rate-limit을 message가 아니라 e.status=429·e.code로만 노출할 수 있음) → 텍스트 폴백.
  const st = e && (e.status ?? e.statusCode ?? e.code)
  if (st === 429 || st === 503 || st === 529 || st === '429' || st === '503' || st === '529') return true
  return TRANSIENT_RE.test(String((e && (e.message || (e.toString && e.toString()))) || e || ''))
}
const reviewAgent = (prompt, label, phase, schema, fallbackModel) =>
  reviewerAgent
    ? agent(prompt, { label, phase, schema, agentType: reviewerAgent }).catch((e) => {
        if (isTransientErr(e)) throw e // 일시적(rate-limit/timeout) → 폴백 금지, 상위가 DEGRADED로 격리(rate-limit 악화 방지)
        // 비-일시적(agentType 미등록 등 영구오류) → opus 모델 폴백(verify가 silent no-op으로 무너지지 않게)
        reviewerFallbacks++
        if (!reviewerFallbackWarned) {
          reviewerFallbackWarned = true
          log(`⚠ reviewer agentType 폴백 → opus 모델(effort/read-only 고정 상실 가능). 일시적 오류는 폴백 대신 DEGRADED로 격리.`)
        }
        return agent(prompt, { label, phase, schema, model: fallbackModel })
      })
    : agent(prompt, { label, phase, schema, model: fallbackModel })

const FINDINGS = {
  type: 'object',
  additionalProperties: false,
  required: ['summary', 'findings'],
  properties: {
    summary: { type: 'string', description: '이 단위의 전반 평가 1~3문장 (한국어)' },
    findings: {
      type: 'array',
      maxItems: 12,
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['title', 'severity', 'where', 'evidence', 'impact', 'recommendation', 'confidence'],
        properties: {
          title: { type: 'string' },
          severity: { enum: ['critical', 'high', 'medium', 'low'] },
          where: { type: 'string', description: '파일:줄 또는 화면/위치' },
          evidence: { type: 'string', description: '실제로 읽고 본 것 — 추측 금지, 불확실하면 confidence를 낮춰 명시' },
          impact: { type: 'string' },
          recommendation: { type: 'string' },
          confidence: { enum: ['high', 'medium', 'low'] },
        },
      },
    },
  },
}

const VERDICT = {
  type: 'object',
  additionalProperties: false,
  required: ['verdict', 'corrected_severity', 'note'],
  properties: {
    verdict: { enum: ['confirmed', 'refuted', 'adjust'], description: 'confirmed=실재·심각도 적정, adjust=실재하나 심각도/표현 수정, refuted=환각·오류·재현불가' },
    corrected_severity: { type: ['string', 'null'], enum: ['critical', 'high', 'medium', 'low', null] },
    note: { type: 'string', description: '검증 근거 (실제 재확인 결과, 한국어)' },
  },
}

const CRITIC = {
  type: 'object',
  additionalProperties: false,
  required: ['missed_findings', 'unexplored_units'],
  properties: {
    missed_findings: { type: 'array', maxItems: 8, items: FINDINGS.properties.findings.items },
    unexplored_units: {
      type: 'array',
      maxItems: 6,
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['key', 'prompt'],
        properties: {
          key: { type: 'string' },
          prompt: { type: 'string', description: '다음 라운드 분석 지시(공통 context는 자동으로 앞에 붙음)' },
        },
      },
    },
  },
}

const keyOf = (f) => `${f.title}@@${f.where}`
const seen = new Set()
const confirmed = []
const refuted = []
const degraded = [] // verify가 throw/실패한 finding — confirmed로 세지 않는다(가짜 green 방지 · LOOP CONTRACT)

const verifyOne = (f, round) =>
  reviewAgent(
    `${CTX}
## adversarial 검증 — 반증을 시도하라
아래 finding이 실재하는지 회의적으로 재검증한다. 인용된 파일/근거를 직접 다시 열어 확인하고 환각·과장·심각도 오류를 잡는다.
기본 태도는 의심 — 증거가 약하면 refuted 또는 adjust. 명백히 실재하면 confirmed.

제목: ${f.title}
심각도(주장): ${f.severity}
위치: ${f.where}
증거(주장): ${f.evidence}
영향(주장): ${f.impact}`,
    `verify:${String(f.title).slice(0, 24)}`,
    `Round ${round}`,
    VERDICT,
    verifyModel,
  )
    .then((v) => ({ ...f, verdict: v }))
    .catch(() => {
      log(`  ⚠ verify 실패: "${String(f.title).slice(0, 36)}" — rate-limit/세션한도 추정 → DEGRADED(미검증, confirmed 아님)`)
      return { ...f, verdict: { verdict: 'error', corrected_severity: null, note: 'verify 호출 실패(throw) — 미검증' } }
    })

// LOOP CONTRACT: refuted→버림, verify 실패(error/null)→degraded, 그 외(confirmed/adjust/unverified)→confirmed
const absorb = (f, unit) => {
  const v = f.verdict
  if (v && v.verdict === 'refuted') refuted.push({ ...f, unit })
  else if (!v || v.verdict === 'error') degraded.push({ ...f, unit, final_severity: f.severity })
  else confirmed.push({ ...f, unit, final_severity: (v.verdict === 'adjust' && v.corrected_severity) || f.severity, verify_state: v.verdict })
}

const coveredUnits = []
const analyzeFailed = [] // analyze 실패 unit.key — coveredUnits로 위장 커버리지 되지 않게 격리(H1)
let criticFailedCount = 0
let dedupSkipped = 0
let pending = units0
let round = 0

while (pending.length && round < maxRounds) {
  round++
  phase(`Round ${round}`)
  log(`Round ${round}: ${pending.length}개 단위 분석 (analyze=${analyzeModel}, verify=${verifyModel})`)

  // canonical no-barrier: 단위별로 분석이 끝나는 즉시 그 단위의 verify가 돈다.
  // batchSize로 동시 분석 단위 수를 제한(청크 사이는 barrier) — API rate-limit cascade 회피.
  // effort:'high' 명시(0.9.0, P1' 2축 배치) — 미지정이면 ultracode 세션의 xhigh를 전 analyze 워커가 상속해
  // fan-out 수만큼 사고 비용이 곱해진다. 정형 분석=high로 충분(verify/critic은 reviewer frontmatter가 xhigh 고정 — 그쪽은 안 아낀다).
  const analyzeStage = (u) =>
    agent(`${CTX}\n${u.prompt}`, { label: `analyze:${u.key}`, phase: `Round ${round}`, schema: FINDINGS, model: u.model || analyzeModel, effort: A.analyzeEffort || 'high' })
  const verifyStage = (r, u) => {
    // 주의: pipeline은 stage1(analyze)이 null이면 stage2를 아예 호출하지 않는다(런타임 실구현 확인)
    // — 이 분기는 방어용 dead path이고 실동작은 배치 루프의 `!r` prong이다. `!r` 가드를 지우면 회귀한다.
    if (!r) return { unit: u.key, findings: [], analyze_failed: true }
    const all = r.findings || []
    const fresh = all.filter((f) => !seen.has(keyOf(f)))
    dedupSkipped += all.length - fresh.length
    fresh.forEach((f) => seen.add(keyOf(f)))
    const toV = fresh.filter(shouldVerify)
    const rest = fresh.filter((f) => !shouldVerify(f)).map((f) => ({ ...f, verdict: { verdict: 'unverified', corrected_severity: null, note: f.severity === 'high' ? 'verify 트리거 미해당(일반 high — 메인이 직접 판정)' : 'verify 트리거 미해당(dial)' } }))
    if (!toV.length) return { unit: u.key, findings: rest }
    return parallel(toV.map((f) => () => verifyOne(f, round))).then((vs) => ({ unit: u.key, findings: [...vs.filter(Boolean), ...rest] }))
  }
  // 인덱스 정렬로 chunk[j]와 res[j]를 대응 — analyze 실패 unit은 coveredUnits가 아니라 analyzeFailed로(H1).
  for (let i = 0; i < pending.length; i += batchSize) {
    const chunk = pending.slice(i, i + batchSize)
    if (pending.length > batchSize) log(`  배치 ${Math.floor(i / batchSize) + 1}/${Math.ceil(pending.length / batchSize)}: ${chunk.map((u) => u.key).join(', ')}`)
    const res = await pipeline(chunk, analyzeStage, verifyStage)
    for (let j = 0; j < chunk.length; j++) {
      const r = res[j]
      if (!r || r.analyze_failed) {
        analyzeFailed.push(chunk[j].key)
        log(`  ⚠ analyze 실패: ${chunk[j].key} — 미커버(DEGRADED)`)
        continue
      }
      coveredUnits.push(chunk[j].key)
      // 하네스 자가감사(WSA-05, CONFIRMED) 수정: critic이 이전 라운드에서 analyze 실패했던 unit을
      // unexplored_units로 재투입해 이번엔 성공하면, analyzeFailed에 남은 옛 등재를 지우지 않으면 같은 key가
      // units_covered와 units_analyze_failed 양쪽에 실려 degraded가 과발화한다.
      const afi = analyzeFailed.indexOf(chunk[j].key)
      if (afi >= 0) analyzeFailed.splice(afi, 1)
      for (const f of r.findings) absorb(f, r.unit)
    }
  }

  pending = []
  if (useCritic) {
    const cr = await reviewAgent(
      `${CTX}
## 완성도 critic — 빠진 게 뭔가
지금까지 분석한 단위: ${coveredUnits.join(', ')}
확정 findings 제목: ${confirmed.map((f) => f.title).join(' | ') || '(없음)'}
안 본 단위·미검증 주장·안 돌린 렌즈를 재점검하라. 새 finding은 missed_findings로(직접 확인한 것만 — 추측 금지),
추가 분석이 필요한 단위는 unexplored_units로(이미 본 단위 재탕 금지). 없으면 둘 다 빈 배열.`,
      `critic:r${round}`,
      `Round ${round}`,
      CRITIC,
      criticModel,
    ).catch(() => {
      criticFailedCount++
      log(`⚠ critic 호출 실패 — 완성도 재점검 미수행(DEGRADED)`)
      return null
    })

    if (cr) {
      // critic 산출물도 verify 재통과 — 무검증 채택 금지(§5)
      const missedAll = cr.missed_findings || []
      const fresh = missedAll.filter((f) => !seen.has(keyOf(f)))
      dedupSkipped += missedAll.length - fresh.length
      fresh.forEach((f) => seen.add(keyOf(f)))
      if (fresh.length) {
        log(`critic이 새 finding ${fresh.length}건 → verify 재통과`)
        const vs = (await parallel(fresh.map((f) => () => verifyOne(f, round)))).filter(Boolean)
        for (const f of vs) absorb(f, 'critic')
      }
      pending = (cr.unexplored_units || []).filter((u) => u && u.key && u.prompt && !coveredUnits.includes(u.key))
      if (pending.length && round < maxRounds) log(`critic이 미탐색 ${pending.length}개 단위 반환 → Round ${round + 1} 재투입`)
      else if (!fresh.length && !pending.length) log('critic 무소득 → 수렴, 정지')
    }
  }
}

const rank = { critical: 0, high: 1, medium: 2, low: 3 }
confirmed.sort((a, b) => (rank[a.final_severity] ?? 9) - (rank[b.final_severity] ?? 9))
degraded.sort((a, b) => (rank[a.final_severity] ?? 9) - (rank[b.final_severity] ?? 9))

// verified/unverified 분리(2026-07-18): confirmed[]에는 reviewer가 실제 통과시킨 것(confirmed/adjust)과,
// verifySeverities 미해당이라 애초에 verify를 안 돌린 것(unverified, medium/low 정책 skip)이 섞여 있었다.
// findings만 보는 소비자가 unverified를 '검증 완료'로 오해하지 않도록 별도 배열로 분리해 노출(findings는 하위호환 union 유지).
const verifiedFindings = confirmed.filter((f) => f.verify_state === 'confirmed' || f.verify_state === 'adjust')
const unverifiedFindings = confirmed.filter((f) => f.verify_state === 'unverified')

// LOOP CONTRACT: degraded(verify 실패)가 1건이라도 있으면 결과는 DEGRADED — 위임자는 낙관 top-line을 보류한다.
if (degraded.length) log(`⚠ DEGRADED: ${degraded.length}건이 verify 실패로 미검증 — confirmed로 세지 않음. 낙관 결론 보류 권장.`)
if (analyzeFailed.length) log(`⚠ DEGRADED: analyze 실패 ${analyzeFailed.length}개 단위 미커버(units_analyze_failed) — 낙관 결론 보류 권장.`)
if (pending.length) log(`⚠ 미탐색 단위 ${pending.length}개 남음(maxRounds 도달) → units_deferred`)

return {
  rounds: round,
  degraded: degraded.length > 0 || analyzeFailed.length > 0 || criticFailedCount > 0, // true면 verify/analyze/critic 부분실패 — 낙관 결론 relay 금지(green≠작동)
  critic_failed: criticFailedCount > 0,
  incomplete_coverage: pending.length > 0, // true면 critic이 반환한 단위를 maxRounds로 다 못 봄
  units_covered: coveredUnits,
  units_analyze_failed: analyzeFailed, // analyze 실패로 커버리지에서 제외된 unit.key(H1 — 위장 covered 방지)
  units_deferred: pending.map((u) => u.key),
  counts: {
    confirmed: confirmed.length, // 하위호환: verified+unverified union 크기(분해는 verified_findings/unverified_findings 배열)
    // 주의: 'verified' 리프명은 아래 by_verdict.verified(confirmed-only)와 값이 달라(여기+adjust) 충돌하므로 top-level엔 두지 않음.
    refuted: refuted.length,
    verify_failed: degraded.length,
    reviewer_fallbacks: reviewerFallbacks,
    dedup_skipped: dedupSkipped,
    by_verdict: {
      verified: confirmed.filter((f) => f.verify_state === 'confirmed').length,
      adjusted: confirmed.filter((f) => f.verify_state === 'adjust').length,
      unverified_skipped: confirmed.filter((f) => f.verify_state === 'unverified').length,
    },
    by_severity: {
      critical: confirmed.filter((f) => f.final_severity === 'critical').length,
      high: confirmed.filter((f) => f.final_severity === 'high').length,
      medium: confirmed.filter((f) => f.final_severity === 'medium').length,
      low: confirmed.filter((f) => f.final_severity === 'low').length,
    },
  },
  findings: confirmed, // 하위호환 union(verified+unverified). '검증됨'만 원하면 verified_findings를 써라.
  verified_findings: verifiedFindings,     // reviewer 통과(confirmed/adjust) — 'confirmed'는 이것에만 정확히 대응
  unverified_findings: unverifiedFindings, // verify 미트리거(정책 skip) — 실재는 미검증, 소비 시 그대로 신뢰 금지
  degraded_findings: degraded, // verify 실패로 미검증 — 별도 추적(confirmed와 분리)
  refuted,
}
