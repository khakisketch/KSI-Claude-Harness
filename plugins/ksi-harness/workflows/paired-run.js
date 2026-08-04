export const meta = {
  name: 'paired-run',
  description: '재사용 tier-검증 골격 — 같은 unit을 challenger(기본 sonnet)·reference(기본 opus) 두 tier로 동일 프롬프트 분석 → reviewer가 gap을 diff하되 reference-only finding을 코드로 재검증(환각 크레딧 차단)해 진짜 recall gap만 집계. model 출시마다 "tier X가 렌즈 Z에서 tier Y를 대체하나"를 싸게 답한다.',
  whenToUse: '새 model 출시·tier 배치 재검토 시. audit-loop(버그 발견)과 shape가 다른 tier-라우팅 검증 골격 — units(키+프롬프트)+context(렌즈 spec)만 넘긴다. 단일 파일 조회엔 오버킬. 0.9.0: 양쪽 analyze에 동일 effort를 명시(pairEffort, 기본 xhigh)해 세션 모드와 무관하게 통제 비교가 성립 — 비-ultracode 세션 제약 해소.',
  phases: [
    { title: 'PairedAnalyze', detail: 'same unit을 challenger·reference가 동일 프롬프트로(통제 비교)' },
    { title: 'GapDiff', detail: 'reviewer가 두 set diff + reference-only 실재 재검증(환각 제외)' },
  ],
}

// ==== CONTRACT (SSOT — 스킬/산문은 의미를 재명세하지 말고 여기를 참조) ====
//  recall_gap    = reference가 잡고 challenger가 놓친 finding 중 코드 재검증으로 실재 확인된 것.
//                  reference 환각·과장은 제외한다 — reference에 공짜 크레딧을 주면 gap이 부풀려진다.
//  verdict/unit  = challenger_sufficient(실재 reference-only 0 또는 low만) · minor_gap(medium 이하) · material_gap(critical/high를 challenger가 놓침).
//  aggregate     = 최악 unit verdict. material 하나라도면 그 렌즈는 reference 유지가 정답.
//  통제(핵심)     = challenger/reference는 **model만** 다르고 프롬프트·context·schema는 동일. 이게 깨지면 비교가 아니라 잡음이다.
//  model ID 예외  = 기본은 alias만(challengerModel/referenceModel, 풀 ID 금지). version-pin이 필요한 신구버전 A/B 비교(예: 특정 모델 스냅샷 간 비교)는 예외적으로 풀 모델 ID 허용.
//  effort        = 양쪽 analyze에 **동일 effort를 명시**(pairEffort dial, 기본 'xhigh') — 세션 effort 상속에 기대지 않아 비-ultracode 세션에서도 통제가 성립(런타임 agent({effort}) 지원 실측 확인). challenger가 xhigh 미지원 tier(haiku·pre-5 Sonnet)면 pairEffort:'high'로 낮춰 통제 유지. gap-diff는 reviewer(opus·xhigh·read-only, 부재 시 opus 폴백).
//  왜 reviewer로 diff = producer(challenger/reference)와 다른 skeptic이 있어야 reference 환각·과장을 걸러 gap을 정직하게 잰다(cross-model error-decorrelation). challenger로 diff하면 correlated blind spot.
//  gap-diff 오류  = agentType 미등록/미상(영구 오류)만 opus model로 폴백. 일시적 오류(rate-limit/timeout)는 폴백 대신 해당 unit을 failed_units로 DEGRADED 격리(rate-limit 악화 방지) — audit-loop.js와 동일 패턴.
//  degraded recommendation = failed_units가 1건이라도 있으면 recommendation은 낙관 결론(downgrade 권장 등) 대신 'DEGRADED — 부분 실패로 결론 보류' 계열로 접힌다. tier 결정은 degraded=false인 run만 근거로 쓸 것.
//  한계          = 스팟체크지 벤치마크 아님(n=units·1회). verdict는 방향 신호 — caveat을 결과에 동봉해 과신을 막는다.
// ====

// ---- args (dial) ----
// units: [{key, prompt}]        필수 — unit별 분석 지시(무엇을 Read/분석). 출력 지시 불필요(스키마 강제).
// context: 공통 맥락(제품·렌즈 spec·규율). 모든 프롬프트 앞에 붙음 — 통제의 핵심이라 강력 권장.
// challengerModel='sonnet'      싼 후보 tier(alias만 — 풀 ID 금지)
// referenceModel='opus'         기준 tier(alias만)
// pairEffort='xhigh'            양쪽 analyze 공통 effort(통제 — challenger가 xhigh 미지원 tier면 'high'로)
// lens='(미지정)'                렌즈 이름(라벨·프롬프트용, 예: '경제무결성·fault-injection')
// gapAgent='reviewer'           gap-diff를 reviewer 서브에이전트(opus·xhigh·read-only)로 라우팅. false면 model 기반(gapModel).
// gapModel='opus'               reviewer 부재/미해석 시 폴백 모델.
let A = args || {}
if (typeof A === 'string') {
  try { A = JSON.parse(A) } catch (e) { return { error: 'args가 문자열인데 JSON 파싱 실패 — 객체로 넘기거나 유효한 JSON으로' } }
}
const units = Array.isArray(A.units) ? A.units.filter((u) => u && u.key && u.prompt) : []
if (!units.length) return { error: 'args.units가 비어 있음 — [{key, prompt}] 필요' }
const CTX = A.context || ''
const challengerModel = A.challengerModel || 'sonnet'
const referenceModel = A.referenceModel || 'opus'
// 통제의 일부: 양쪽 동일 effort 명시 — 세션 모드 무관. challenger가 xhigh 미지원이면 'high'로 낮춰 호출.
const pairEffort = A.pairEffort || 'xhigh'
const lens = A.lens || '(미지정 렌즈)'
const gapAgent = A.gapAgent === undefined ? 'reviewer' : A.gapAgent
const gapModel = A.gapModel || 'opus'

const FIND = {
  type: 'object', additionalProperties: false,
  required: ['summary', 'findings'],
  properties: {
    summary: { type: 'string', description: '이 unit 전반 평가 1~3문장(한국어)' },
    findings: {
      type: 'array', maxItems: 15,
      items: {
        type: 'object', additionalProperties: false,
        required: ['title', 'severity', 'where', 'evidence', 'impact', 'confidence'],
        properties: {
          title: { type: 'string' },
          severity: { enum: ['critical', 'high', 'medium', 'low'] },
          category: { type: 'string', description: '렌즈 내 하위 분류(선택)' },
          where: { type: 'string', description: 'file:line 또는 위치' },
          evidence: { type: 'string', description: '실제로 읽고 본 것 — 추측 금지, 불확실하면 confidence를 낮춰 명시' },
          impact: { type: 'string' },
          confidence: { enum: ['high', 'medium', 'low'] },
        },
      },
    },
  },
}

const GAP = {
  type: 'object', additionalProperties: false,
  required: ['unit', 'reference_only_real', 'reference_only_hallucinated', 'challenger_only_real', 'verdict', 'note'],
  properties: {
    unit: { type: 'string' },
    reference_only_real: {
      type: 'array', maxItems: 12, description: 'reference가 잡고 challenger가 놓친 것 중 코드로 재확인해 실재하는 것(=진짜 recall gap)',
      items: {
        type: 'object', additionalProperties: false, required: ['title', 'where', 'severity', 'why_real'],
        properties: { title: { type: 'string' }, where: { type: 'string' }, severity: { enum: ['critical', 'high', 'medium', 'low'] }, why_real: { type: 'string', description: '재확인 근거(파일:라인)' } },
      },
    },
    reference_only_hallucinated: {
      type: 'array', maxItems: 12, description: 'reference만 냈으나 재검증 시 환각·과장이라 recall gap으로 안 세는 것',
      items: {
        type: 'object', additionalProperties: false, required: ['title', 'why_not_real'],
        properties: { title: { type: 'string' }, why_not_real: { type: 'string' } },
      },
    },
    challenger_only_real: {
      type: 'array', maxItems: 12, description: 'challenger가 잡고 reference가 놓친 것 중 실재하는 것',
      items: {
        type: 'object', additionalProperties: false, required: ['title', 'where'],
        properties: { title: { type: 'string' }, where: { type: 'string' } },
      },
    },
    verdict: { enum: ['challenger_sufficient', 'minor_gap', 'material_gap'], description: 'challenger_sufficient=실재 reference-only 0 또는 low만, minor_gap=medium 이하, material_gap=critical/high를 challenger가 놓침' },
    note: { type: 'string', description: '겹침 처리·심각도 조정·특기 반증관계(한국어)' },
  },
}

// 오류 분류(audit-loop.js 패턴 이식, 하네스 메타감사 medium finding A 수정): agentType 실패 시
// '무조건' opus 모델로 폴백하면 rate-limit/timeout류 일시적 오류에도 같은 비싼 opus를 즉시 재호출해
// rate-limit을 되레 악화시킨다. 일시적 오류는 폴백하지 말고 rethrow해 호출부가 DEGRADED로 격리하게 하고,
// agentType 미등록/미상 오류(영구 오류)만 opus로 폴백한다.
const TRANSIENT_RE = /rate.?limit|429|overloaded|529|503|timeout|timed out|too many requests|quota|session (?:limit|token)|context (?:window|length)|network|ECONN|ETIMEDOUT/i
const isTransientErr = (e) => {
  // 구조화 필드 우선(runtime이 rate-limit을 message가 아니라 e.status=429·e.code로만 노출할 수 있음) → 텍스트 폴백.
  const st = e && (e.status ?? e.statusCode ?? e.code)
  if (st === 429 || st === 503 || st === 529 || st === '429' || st === '503' || st === '529') return true
  return TRANSIENT_RE.test(String((e && (e.message || (e.toString && e.toString()))) || e || ''))
}
// gap-diff = reviewer tier(opus·xhigh·read-only). agentType 미등록/미해석(영구 오류)이면 model 기반 opus로 graceful
// 폴백(silent no-op 방지). rate-limit/timeout 등 일시적 오류는 폴백하지 않고 그대로 rethrow — 호출부(아래 gap-diff
// 처리부)가 catch해 해당 unit을 DEGRADED로 격리한다(rate-limit 악화 방지).
const reviewAgent = (prompt, label, ph, schema) =>
  gapAgent
    ? agent(prompt, { label, phase: ph, schema, agentType: gapAgent }).catch((e) => {
        if (isTransientErr(e)) throw e // 일시적(rate-limit/timeout) → 폴백 금지, 호출부가 DEGRADED로 격리
        return agent(prompt, { label, phase: ph, schema, model: gapModel }) // 영구 오류만 opus 모델 폴백
      })
    : agent(prompt, { label, phase: ph, schema, model: gapModel })

const fmt = (set) =>
  !set
    ? '(분석 실패/null)'
    : (set.findings || []).map((f) => `- [${f.severity}${f.category ? '/' + f.category : ''}] ${f.title} @ ${f.where} (conf ${f.confidence})\n    evidence: ${f.evidence}`).join('\n') || '(finding 0건)'

phase('PairedAnalyze')
log(`paired-run: ${units.length}개 unit × {challenger=${challengerModel}, reference=${referenceModel}} · 렌즈=${lens}`)

// H2: challenger/reference 중 한쪽만 실패한 unit은 gap-diff를 skip하고 여기로 격리(DEGRADED) — 침묵 진행 금지.
const failedUnits = []

// canonical no-barrier: unit별로 challenger·reference 분석이 끝나는 즉시 그 unit의 gap-diff가 돈다.
const perUnit = (
  await pipeline(
    units,
    async (u) => {
      const [c, r] = await parallel([
        () => agent(`${CTX}\n${u.prompt}`, { label: `analyze:${u.key}:challenger(${challengerModel})`, phase: 'PairedAnalyze', model: challengerModel, effort: pairEffort, schema: FIND }),
        () => agent(`${CTX}\n${u.prompt}`, { label: `analyze:${u.key}:reference(${referenceModel})`, phase: 'PairedAnalyze', model: referenceModel, effort: pairEffort, schema: FIND }),
      ])
      return { key: u.key, challenger: c, reference: r }
    },
    async (res) => {
      if (!res) return null
      const cFail = !res.challenger
      const rFail = !res.reference
      if (cFail || rFail) {
        const failed_side = cFail && rFail ? 'both' : cFail ? 'challenger' : 'reference'
        failedUnits.push({ unit: res.key, failed_side })
        log(`⚠ ${res.key}: ${failed_side} 분석 실패 — gap-diff 스킵(DEGRADED)`)
        return null
      }
      const prompt = `${CTX}

## paired-run gap diff — unit "${res.key}" · 렌즈: ${lens}
같은 unit을 challenger(${challengerModel})와 reference(${referenceModel})가 동일 프롬프트로 분석했다. 임무: **reference가 잡고 challenger가 놓친 finding이 실재하는지** 근거(파일:라인·명령)를 직접 다시 열어 재검증한다 — 환각·과장이면 recall gap으로 세지 않는다(reference에 공짜 크레딧 금지). reference의 과장 심각도는 down-adjust. challenger만 잡은 실재 finding도 본다. 기본자세는 의심.

### CHALLENGER(${challengerModel}) findings:
${fmt(res.challenger)}

### REFERENCE(${referenceModel}) findings:
${fmt(res.reference)}

두 set을 semantic하게 대조(제목이 달라도 같은 결함이면 겹침으로 본다). reference_only 후보를 실제로 재확인 → 실재=reference_only_real, 환각/과장=reference_only_hallucinated. verdict = 실재하는 reference_only의 최고 심각도 기준(critical/high면 material_gap · medium이면 minor_gap · 없거나 low만이면 challenger_sufficient).`
      // reviewAgent는 일시적 오류를 rethrow한다(위 정의) — pipeline 상위로 크래시가 번지지 않게 여기서
      // catch해 null로 접는다. 이후 처리는 !g 분기가 편측 analyze 실패와 동일하게 DEGRADED로 흡수한다.
      const g = await reviewAgent(prompt, `gapdiff:${res.key}`, 'GapDiff', GAP).catch((e) => {
        log(`  ⚠ ${res.key}: gap-diff 호출 실패(${isTransientErr(e) ? 'rate-limit/timeout 추정 — 일시적' : '오류'}) — DEGRADED(미검증)`)
        return null
      })
      if (!g) {
        // 하네스 자가감사(WSA-01, CONFIRMED) 수정: gap-diff 실패를 failedUnits에 넣지 않고 그냥
        // null 반환하던 silent drop — degraded=false로 남아 tier-downgrade 판정에서 미검증 unit이 은폐될 수
        // 있었다. analyze 편측 실패와 동일하게 DEGRADED 격리.
        failedUnits.push({ unit: res.key, failed_side: 'gapdiff' })
        log(`⚠ ${res.key}: gap-diff 실패 — DEGRADED(미검증, challenger_sufficient로 세지 않음)`)
        return null
      }
      // verdict는 reviewer 자기보고를 신뢰하지 않고 reference_only_real의 severity로 JS에서 결정적으로 재계산(unit 키도 강제 주입).
      const realSeverities = (g.reference_only_real || []).map((f) => f.severity)
      const verdict = realSeverities.includes('critical') || realSeverities.includes('high')
        ? 'material_gap'
        : realSeverities.includes('medium')
          ? 'minor_gap'
          : 'challenger_sufficient'
      if (g.verdict && g.verdict !== verdict) {
        log(`⚠ ${res.key}: reviewer 자기보고 verdict(${g.verdict}) ≠ severity 재계산(${verdict}) — 재계산값 채택`)
      }
      return { ...g, unit: res.key, model_verdict: g.verdict, verdict }
    },
  )
).filter(Boolean)

// aggregate = 최악 verdict. material 하나라도면 그 렌즈는 reference 유지.
// perUnit은 이미 failedUnits(편측 실패)를 제외한 성공 gap-diff만 담고 있으므로, 실패 unit이 challenger_sufficient로 잘못 세어질 편향이 없다.
const rank = { material_gap: 0, minor_gap: 1, challenger_sufficient: 2 }
const worst = perUnit.length ? perUnit.reduce((w, g) => (rank[g.verdict] < rank[w] ? g.verdict : w), 'challenger_sufficient') : null
const baseRecommendation =
  worst === 'material_gap'
    ? `이 렌즈는 ${referenceModel} 유지 — challenger(${challengerModel})가 real critical/high를 놓침(material_gap).`
    : worst === 'minor_gap'
      ? `${challengerModel} 근접 — 실재 reference-only가 medium 이하뿐. 저 miss-cost 렌즈면 fit-driven downgrade 여지, 고 miss-cost(자금·안전)면 ${referenceModel} 유지 권장.`
      : worst === 'challenger_sufficient'
        ? `${challengerModel} 충분 — 실재 reference-only 0 또는 low만. fit-driven downgrade 후보(다른 대상/unit으로 재확인 권장).`
        : '(unit 전부 실패 — 결론 없음)'
// 하네스 메타감사 medium finding B 수정: 부분 실패(failedUnits>0) 상태에서도 baseRecommendation이 그대로
// 나가면 downgrade 권장('충분'·'근접') 같은 낙관 결론이 partial run 근거로 relay될 수 있다(green≠작동의
// tier-downgrade판). degraded면 recommendation을 DEGRADED 계열로 접고, base는 '완료분 한정 잠정' 참고로만 남긴다
// — tier 결정 근거로 쓰지 말라고 명시(특히 material_gap이 아닌 낙관 verdict일 때 오용 위험이 크다).
const recommendation =
  failedUnits.length > 0
    ? `DEGRADED — 부분 실패로 결론 보류(${units.length}개 unit 중 ${perUnit.length}개만 gap-diff 완료, ${failedUnits.length}개 실패). tier 결정 근거로 쓰지 말고 재실행 권장. (참고, 완료분 한정 잠정 verdict=${worst || '(없음)'}: ${baseRecommendation})`
    : baseRecommendation

const halluc = perUnit.reduce((n, g) => n + (g.reference_only_hallucinated || []).length, 0)
if (halluc) log(`※ reference가 낸 것 중 ${halluc}건이 재검증서 환각/과장으로 걸러짐 — 그만큼 gap을 부풀리지 않음(정상).`)
if (failedUnits.length) log(`⚠ DEGRADED: ${failedUnits.length}개 unit이 편측/양측 분석 실패 또는 gap-diff 자체 실패로 제외됨 — aggregate_verdict에 반영되지 않음.`)
log(`aggregate: ${worst} — ${recommendation}`)

return {
  lens,
  challenger: challengerModel,
  reference: referenceModel,
  aggregate_verdict: worst,
  recommendation,
  degraded: failedUnits.length > 0,
  failed_units: failedUnits,
  caveat: `스팟체크 — n=${perUnit.length} unit(요청 ${units.length}건 중 분석 완료)·1회 실행. verdict는 방향 신호지 벤치마크 아님(labeled set + precision/recall이 아님). 다른 대상/렌즈로 재확인 시 신뢰 상승.`,
  reference_hallucinated_count: halluc,
  per_unit: perUnit,
}
