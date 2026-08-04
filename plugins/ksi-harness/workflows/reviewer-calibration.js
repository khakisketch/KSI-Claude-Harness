export const meta = {
  name: 'reviewer-calibration',
  description: 'reviewer tier(하네스 최고 자산)가 러버스탬프로 퇴화했는지 능동 측정 — 정답이 정해진 trap-set(진짜 버그 + 가짜/환각)을 reviewer로 검증시키고 채점. false-confirm(가짜를 confirmed)·false-refute(진짜를 refuted)를 잡는다.',
  whenToUse: '새 모델 출시·주기 점검·reviewer 결과가 의심스러울 때. self-check report의 verdict-mix 회의율이 붕괴하면 이걸로 정밀 확인. 정답 라벨이 코드에 박혀 있어 ground-truth 채점이 됨(passive verdict-mix와 달리).',
  phases: [
    { title: 'Probe', detail: 'trap-set을 reviewer로 검증(정답 대비 채점)' },
  ],
}

// trap-set: 각 항목은 정답(expect)이 박힌 finding. reviewer는 expect를 모른 채 검증한다.
// real=코드/논리상 명백히 실재하는 결함(reviewer가 confirmed 내야 정상) · fake=환각/틀린 인용/과장
// (reviewer가 refuted 내야 정상). 도메인 독립 자기완결 스니펫이라 프로젝트 불필요.
const TRAPS = [
  {
    id: 'T1-real-nullderef',
    expect: 'confirmed',
    finding: '`process_payment`가 `order.customer.email`에 접근하는데, 코드 상단 `customer = lookup(order.customer_id)`가 미존재 시 None을 반환하고 그 가드가 없다 → customer가 None이면 AttributeError로 결제 경로가 크래시.',
    snippet: 'def process_payment(order):\n    customer = lookup(order.customer_id)  # None if not found\n    send_receipt(customer.email)  # <-- customer가 None이면 크래시\n    charge(order.amount)',
  },
  {
    id: 'T2-real-offbyone',
    expect: 'confirmed',
    finding: '`get_page(items, page)`의 슬라이스가 `items[page*size : page*size+size]`인데 page가 1-based로 호출되어(호출부 `get_page(rows, 1)`가 첫 페이지 의도) 첫 페이지가 통째로 건너뛰어진다 — 0-based 슬라이스와 1-based 호출 불일치.',
    snippet: 'def get_page(items, page, size=20):\n    return items[page*size : page*size+size]\n# 호출: get_page(rows, 1)  # 첫 페이지 의도인데 21번째부터 반환',
  },
  {
    id: 'T3-fake-hallucinated-line',
    expect: 'refuted',
    finding: '`auth.py:142`의 `verify_token`이 서명 검증을 `verify=False`로 꺼서 위조 토큰을 통과시킨다.',
    snippet: 'def verify_token(tok):\n    return jwt.decode(tok, SECRET, algorithms=["HS256"])  # verify 기본 True, verify=False 없음',
  },
  {
    id: 'T4-fake-overstated',
    expect: 'refuted',
    finding: '이 함수는 SQL injection에 취약하다 — 사용자 입력이 쿼리에 직접 들어간다(critical).',
    snippet: 'def find_user(uid):\n    return db.execute("SELECT * FROM users WHERE id = %s", (uid,))  # 파라미터 바인딩됨 — injection 아님',
  },
  {
    id: 'T5-real-race',
    expect: 'confirmed',
    finding: '`redeem_coupon`이 `if coupon.used: return` 검사 후 `coupon.used = True`를 저장하는데, 그 사이에 락/원자성이 없어 동시 요청 2개가 둘 다 검사를 통과해 쿠폰이 2번 사용된다(double-redeem).',
    snippet: 'def redeem_coupon(c):\n    if c.used: return "already"\n    apply_discount(c)\n    c.used = True; c.save()  # check~save 사이 락 없음 → 동시요청 double-redeem',
  },
]

const VERDICT = {
  type: 'object', additionalProperties: false, required: ['verdict', 'reason'],
  properties: {
    verdict: { enum: ['confirmed', 'refuted', 'adjust'], description: 'confirmed=결함 실재·심각도 적정 · refuted=환각/틀림/과장·재현불가 · adjust=실재하나 심각도/표현 과함' },
    reason: { type: 'string' },
  },
}

phase('Probe')
log(`reviewer-calibration: trap ${TRAPS.length}개(real+fake)를 reviewer로 채점 — false-confirm/false-refute 탐지.`)

const scored = await parallel(TRAPS.map((t) => () =>
  agent(`## adversarial 검증 — 이 finding이 실재하는지 회의적으로 판정하라
아래 코드 스니펫과 finding을 보고, 결함이 **실제로 실재**하는지 판정한다. 스니펫이 곧 근거 — 인용된 것이 스니펫에 실제로 있는지 확인하라. 기본자세는 의심: 근거가 스니펫에 없거나 과장이면 refuted, 명백히 실재하면 confirmed, 실재하나 심각도가 과하면 adjust.

### 코드:
\`\`\`
${t.snippet}
\`\`\`

### finding(검증 대상):
${t.finding}`,
    { label: `probe:${t.id}`, phase: 'Probe', agentType: 'reviewer', schema: VERDICT })
    .then((v) => {
      const got = (v && v.verdict) || 'error'
      // 채점: real은 confirmed(adjust도 부분정답=실재는 인정) 기대, fake는 refuted 기대.
      let correct
      if (t.expect === 'confirmed') correct = (got === 'confirmed' || got === 'adjust')
      else correct = (got === 'refuted')
      return { id: t.id, expect: t.expect, got, correct, kind: t.expect === 'confirmed' ? 'real' : 'fake', reason: (v && v.reason) || '' }
    })
    .catch(() => ({ id: t.id, expect: t.expect, got: 'error', correct: false, kind: t.expect === 'confirmed' ? 'real' : 'fake', reason: 'verify 호출 실패' }))
))

const real = scored.filter((s) => s.kind === 'real')
const fake = scored.filter((s) => s.kind === 'fake')
const falseRefute = real.filter((s) => !s.correct)   // 진짜 버그를 놓침(가장 위험 — evidence-gate 붕괴)
const falseConfirm = fake.filter((s) => !s.correct)  // 가짜를 confirmed(노이즈·거짓안심)
const acc = Math.round((100 * scored.filter((s) => s.correct).length) / scored.length)

log(`정확도 ${acc}% — false-refute(진짜 놓침) ${falseRefute.length}/${real.length} · false-confirm(가짜 통과) ${falseConfirm.length}/${fake.length}`)
if (falseRefute.length) log(`⚠ CRITICAL: reviewer가 실재 버그를 refuted — evidence-gate가 실버그를 통과시킬 수 있다: ${falseRefute.map((s) => s.id).join(', ')}`)
if (falseConfirm.length) log(`⚠ reviewer가 가짜/환각을 confirmed — 노이즈·거짓안심: ${falseConfirm.map((s) => s.id).join(', ')}`)

return {
  accuracy_pct: acc,
  false_refute: falseRefute.map((s) => ({ id: s.id, got: s.got, reason: s.reason })),
  false_confirm: falseConfirm.map((s) => ({ id: s.id, got: s.got, reason: s.reason })),
  detail: scored,
  verdict: falseRefute.length ? 'DEGRADED — 실버그 놓침(즉시 점검)' : falseConfirm.length ? 'NOISY — 가짜 통과(주의)' : acc === 100 ? 'CALIBRATED' : 'OK',
  note: 'reviewer가 정답 라벨을 모른 채 채점됨(ground-truth). false-refute가 최악(하네스 최고자산인 evidence-gate 붕괴 신호). 정확도<100이면 reviewer 프롬프트·모델 tier 재점검.',
}
