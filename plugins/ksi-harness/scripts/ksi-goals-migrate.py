#!/usr/bin/env python3
"""ksi-goals-migrate — 기존 .ksi 원장에 kind 소급 분류 + '전체 CI류' completion_criteria 정리.

배경: kind/verification 필드 도입 이전 레코드는 전부 'unclassified'로 읽힌다(ksi-goals.py의
goal_kind() 폴백) — gate는 안전하게 strict로 막히지만, report/status --json의 kind별 분리(제품 현황 vs
감사 findings)는 안 된다. 이 스크립트는 제목/blocked_by 텍스트 휴리스틱으로 kind를 소급 배정하고,
완료기준에 박힌 '전체 CI 통과' 류 문구를 걷어낸다(그건 goal 완료 조건이 아니라 병합/릴리즈 체크포인트의
일 — goals SKILL.md 계약. 다음 감사 때 같은 기준이 재사용되는 걸 막는다).

기본은 dry-run(아무것도 안 씀 — goals.json 미변경, 새 파일 생성도 없음). --apply만 실제로 고치고,
쓰기 전 `goals.json.premigrate-<YYYYMMDD-HHMMSS>`로 백업한다.

휴리스틱은 신뢰도가 낮다 — 특히 product 버킷(나머지 전부)은 매 항목 '검토 필요'로 표시된다. 이 스크립트는
자동 확정기가 아니라 초안 생성기다: 사람이 dry-run 출력을 눈으로 훑고, 틀린 분류는 `ksi-goals.py`로
직접 고치는 걸 전제한다. 이미 kind가 있는 goal은 재분류하지 않는다(사람이 이미 register --kind로
확정했거나 이 스크립트를 한 번 --apply한 것 — 소급 대상은 kind 없는 레코드뿐).

ksi-goals.py의 paths()/락(_lock_ex)/log() 관례를 그대로 재사용한다(importlib — 파일명에 하이픈이 있어
`import ksi_goals`가 안 되므로 경로로 직접 로드).

사용: ksi-goals-migrate.py --dir <프로젝트경로> [--apply]
"""
import argparse
import datetime
import importlib.util
import os
import re
import shutil
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("ksi_goals", os.path.join(_HERE, "ksi-goals.py"))
ksi_goals = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ksi_goals)


# --- 분류 휴리스틱(우선순위 순 — 먼저 맞는 것 채택). 태그 표기·프로젝트별 관용구가 섞여 있어 완벽할 수
#     없다 — 그래서 product(나머지 전부)는 항상 '검토 필요'로 표시하고, decision/hardening도 오분류
#     가능성을 report의 reason 근거로 남긴다(사람이 왜 이렇게 분류됐는지 바로 훑을 수 있게).
# 명시 태그/접두 — 무조건 decision(최우선). owner:/legal: 접두는 실측(한 프로젝트 6건)상 진짜
# 오너/법무 소관이라 그대로 유지.
DECISION_TAG_RE = re.compile(r"\[대표자(결정|액션)\]")
DECISION_PREFIX_RE = re.compile(r"^\s*(owner|legal):", re.IGNORECASE)
# 그 외 '사람만 할 수 있는 행위' 키워드 — 태그가 아니라 언급이라 하드닝 신호와 함께 있으면 hardening이 이긴다
# (아래 classify() 참조 — 한 프로젝트에서 실측된 두 goal처럼 '하드닝 작업이 대표자 승인 대기 중'인 걸 decision으로
# 오분류하던 문제의 교정. 태그가 전혀 없을 때만 진짜 decision).
DECISION_KEYWORD_RE = re.compile(r"대표자|오너|법무|활용신청|계정\s*발급")

# 실측: 심각도 태그가 대괄호 '맨 앞'에만 오지 않는다 — '[<선행id>감사이월·low묶음]'처럼
# prefix 뒤에 오는 경우가 흔해 대괄호 어디든 찾는다. \b는 쓰지 않는다 — Python 유니코드 \b는 한글도 \w로
# 쳐서 'medium묶음'처럼 라틴+한글이 공백 없이 붙으면 경계가 안 생겨(never matches) 놓친다. 대신 좌우 모두
# '다음/이전 글자가 라틴 알파벳이면 거부'로 대체(하이픈/한글/기호/끝은 전부 허용) — 'highest' 같은 오탐만 막는다.
HARDENING_TAG_RE = re.compile(
    r"\[[^\]]*?(?<![a-zA-Z])(critical|high|medium|med|low)(?![a-zA-Z])[^\]]*\]", re.IGNORECASE)
HARDENING_LITERAL_RE = re.compile(r"\bSCA\b|감사이월|감사HIGH|후속", re.IGNORECASE)
# 'ops:'는 title prefix 신호에서 뺐다(실측: 한 프로젝트의 여러 goal에서 'ops:'가 프로젝트마다
# 감사 하드닝과 오너 소관 운영 둘 다에 쓰여서 decision/hardening을 못 가른다. 오분류 비용이 비대칭이다 —
# hardening을 decision으로 잘못 분류하면 목록이 지저분해질 뿐이지만, decision을 hardening으로 잘못 분류하면
# '사람이 정해야 진행되는 일'이 보완 작업 더미에 묻힌다. 신뢰 신호를 줄여 후자 방향 오류를 피한다).
# id 컨벤션의 'ops-'(예: ops-serving-hardening)는 안 건드린다 — 별도 신호(ID_HARDENING_RE)라 여기 영향 없음.
HARDENING_PREFIX_RE = re.compile(r"^\s*(ci|refactor):", re.IGNORECASE)
# '잔여'·'커버리지'는 뺐다(실측: 한 프로젝트의 진척차트 '잔여 절/성토'· 다른 프로젝트의
# '커버리지 경로'가 일상어/도메인어에 걸려 오탐 — 둘 다 하드닝과 무관한 흔한 단어라 신호로 너무 약하다).
HARDENING_KEYWORD_RE = re.compile(r"회귀|린트|취약|하드닝|hardening", re.IGNORECASE)
# 대괄호 태그 안에서만 인정하는 감사/하드닝성 어휘(대괄호 밖 일상어는 여전히 신호로 안 쓴다 — '잔여'에서
# 확립한 원칙의 확장). 심각도 태그([high]류)가 아닌 감사/운영 결함 태그가 많아 실측(한 프로젝트)으로 넓혔다:
# [감사2 보안config]·[운영결함]·[데이터위생]·[UAT청소]·[무결성감사]·[핵심결함]·[시각검증 관측]·[브랜드 잔재]·
# [프로세스 안전] 류. 대괄호 스코프라 [제품결정]·[가치A#1/...]·[G201]류(태그에 이 어휘가 없음)는 안 걸린다 —
# [G205] ui-audit 1차 웨이브처럼 본문에 다른 신호어가 있어도 태그 자체가 [G205]면 이 정규식은 안 본다.
HARDENING_BRACKET_KEYWORDS_RE = re.compile(
    r"\[[^\]]*(잔여|감사|운영|데이터위생|무결성|핵심결함|시각검증|잔재|UAT|프로세스\s*안전|위생)[^\]]*\]",
    re.IGNORECASE,
)
# goal id 자체의 하드닝 컨벤션 — title/blocked_by만 보던 원래 규칙의 사각(실측: 한 프로젝트의
# audit-*/*-hardening 7건, 다른 프로젝트의 AUD-1~5 5건이 title에 리터럴 키워드가 없어 전부 product로
# 떨어졌었다). `^AUD-\d+$`는 `^aud[-_]`에 이미 포함되지만 지시된 패턴을 그대로 남겨 명시적으로 둔다.
ID_HARDENING_RE = re.compile(
    r"^(audit|aud|ops|ci|chore|fix|hardening)[-_]|[-_](hardening|audit)$|^AUD-\d+$", re.IGNORECASE)

# 완료기준에서 걷어낼 문구 — '관계없는 목표에 전체 스위트/전체 CI의 초록불을 완료 조건으로 건 것'만 대상
# (좁힘: 처음엔 'CI 통과'·'전량 통과' 같은 넓은 패턴을 썼는데, 실측 41건 중 대부분이
# 'SCA CI 게이트' 구축 자체가 목표거나 범위가 goal 고유 테스트인 것들이라 지우면 완료기준이 통째로 비는
# goal이 무더기로 생겼다 — 부채를 줄이는 게 아니라 만드는 것. 애매하면 남긴다).
CI_CRITERIA_RE = re.compile(
    r"CI\s*green|전체\s*CI|풀\s*CI|CI\s*전량|전체\s*테스트\s*green|전체\s*스위트|"
    r"pytest\s*전량|typecheck\s*전체|full\s*CI",
    re.IGNORECASE,
)
# goal 제목 자체가 CI/테스트/게이트 인프라 구축인 경우 그 goal의 criteria는 아예 건드리지 않는다 — '전체'가
# 이 goal 고유 스위트를 가리키는지 레포 전체를 가리키는지 구분 못 하므로 안전한 쪽(보존)으로 폴백.
# \b 대신 좌우 라틴 인접 거부를 쓴다(위 HARDENING_TAG_RE와 동일 이유 — 'CI설정'처럼 한글이 바로 붙는 경우 대비).
TITLE_CI_GUARD_RE = re.compile(r"(?<![a-zA-Z])CI(?![a-zA-Z])|게이트|테스트", re.IGNORECASE)


def _hardening_signal(gid, title):
    """(있음?, reason) — 심각도 태그/id 컨벤션/리터럴/접두/키워드 중 하나라도 있으면 True.
    decision 키워드(대표자/오너 등)가 title/blocked_by에 있어도 이 신호가 있으면 hardening이 이긴다
    (한 프로젝트에서 실측된 두 goal — '하드닝 작업이 대표자 승인 대기 중'을 decision으로 삼키던 문제 교정)."""
    if HARDENING_TAG_RE.search(title):
        return True, "제목에 심각도 태그([critical/high/medium/low] 류)"
    m = HARDENING_BRACKET_KEYWORDS_RE.search(title)
    if m:
        return True, f"제목 대괄호 태그 안에 감사/하드닝성 어휘('{m.group(1)}' — 태그 밖 일상어는 신호로 안 씀)"
    if ID_HARDENING_RE.search(gid or ""):
        return True, f"goal id가 하드닝 컨벤션(audit-/aud-/ops-/AUD-N 등, id={gid})"
    if HARDENING_LITERAL_RE.search(title):
        return True, "제목에 SCA/감사이월/감사HIGH/후속"
    if HARDENING_PREFIX_RE.match(title):
        return True, "제목이 ci:/refactor:로 시작"
    if HARDENING_KEYWORD_RE.search(title):
        return True, "제목에 하드닝 키워드(회귀/린트/취약/하드닝)"
    return False, None


def classify(goal):
    """(kind, reason) — reason은 사람이 분류 근거를 바로 훑을 때 쓰는 짧은 문자열."""
    gid = goal.get("id") or ""
    title = goal.get("title") or ""
    blocked_by = goal.get("blocked_by") or ""
    decision_haystack = f"{title} {blocked_by}"

    # 1순위(무조건, 최우선): 명시 태그·접두 — 결정 자체가 이 goal의 산출물인 것만.
    if DECISION_TAG_RE.search(title):
        return "decision", "제목에 [대표자결정/액션] 태그(최우선)"
    if DECISION_PREFIX_RE.match(title):
        return "decision", "제목이 owner:/legal:로 시작(오너/법무 소관 — 최우선 유지)"

    hardening, hardening_reason = _hardening_signal(gid, title)

    # 그 외 '대표자/오너/법무/활용신청/계정발급' 언급 — 하드닝 신호가 함께 있으면 그 goal의 실질은
    # 하드닝 작업(감사대응/기술부채)이 대표자 승인을 기다리는 것이지 '결정 자체'가 산출물이 아니다.
    if DECISION_KEYWORD_RE.search(decision_haystack):
        if hardening:
            return "hardening", f"{hardening_reason} (대표자/오너 언급 동반하나 하드닝 신호 우선)"
        return "decision", "제목/blocked_by에 사람만 할 수 있는 행위 키워드(하드닝 태그 없음)"

    if hardening:
        return "hardening", hardening_reason

    return "product", "휴리스틱 미매칭(기본 버킷) — 자동분류 최저신뢰, 검토 필요"


def clean_criteria(title, criteria):
    """(kept, removed, flagged) — removed는 실제 제거(kept가 안 빔), flagged는 '지우면 0개'라
    안 지우고 원본 유지한 채 사람이 다시 써야 함을 알리는 리스트. 제목이 CI/게이트/테스트를 포함하면
    (그 goal 자체가 CI/테스트 인프라 구축일 수 있어) criteria를 아예 건드리지 않는다."""
    original = list(criteria or [])
    if TITLE_CI_GUARD_RE.search(title or ""):
        return original, [], []
    matched = [c for c in original if CI_CRITERIA_RE.search(c)]
    if not matched:
        return original, [], []
    kept = [c for c in original if not CI_CRITERIA_RE.search(c)]
    if not kept:
        # 전량 제거하면 0개로 감 — 마지막 남은 걸 지우지 않는다. 원본 유지 + 사람이 다시 쓰라고 플래그.
        return original, [], matched
    return kept, matched, []


def _short(s, n=60):
    s = " ".join(str(s or "").split())
    return s if len(s) <= n else s[: n - 1].rstrip() + "…"


def plan(data):
    """쓰기 없이 순수 계산 — (kind별 (goal, reason) 목록, criteria 제거 목록, criteria 보류-플래그 목록,
    이미 분류돼 스킵된 수)."""
    by_kind = {"product": [], "hardening": [], "decision": []}
    already_classified = 0
    for g in data.get("goals", []):
        if g.get("kind"):
            # 이미 register --kind로 분류됐거나 이 스크립트를 한 번 --apply한 goal — 소급 재분류 대상이 아니다.
            already_classified += 1
            continue
        kind, reason = classify(g)
        by_kind[kind].append((g, reason))

    criteria_removals = []  # (goal_id, removed_list, kept_list) — 실제 제거(kept 안 빔)
    criteria_flagged = []   # (goal_id, matched_list) — 지우면 0개라 원본 유지, 사람이 다시 써야 함
    for g in data.get("goals", []):
        kept, removed, flagged = clean_criteria(g.get("title"), g.get("completion_criteria"))
        if removed:
            criteria_removals.append((g["id"], removed, kept))
        elif flagged:
            criteria_flagged.append((g["id"], flagged))

    return by_kind, criteria_removals, criteria_flagged, already_classified


def render_report(project, by_kind, criteria_removals, criteria_flagged, already_classified):
    lines = [f"=== {project} ==="]
    for kind in ("decision", "hardening", "product"):
        items = by_kind[kind]
        if not items:
            continue
        tag = "  (자동분류 최저신뢰 — 전부 검토 필요)" if kind == "product" else ""
        lines.append(f"\n[{kind}] {len(items)}건{tag}")
        for g, reason in items:
            mark = " ⚠검토 필요" if kind == "product" else ""
            lines.append(f"  {g['id']} · {g['status']} · {_short(g['title'])}{mark}")

    removed_total = sum(len(r[1]) for r in criteria_removals)
    if criteria_removals:
        lines.append(f"\n[완료기준 정리] {removed_total}건 제거 예정 (goal {len(criteria_removals)}개)")
        for gid, removed, _kept in criteria_removals:
            shown = ", ".join(f"'{_short(r, 40)}'" for r in removed)
            lines.append(f"  {gid}: {shown}")

    if criteria_flagged:
        lines.append(f"\n[완료기준 보류] {len(criteria_flagged)}건 — 지우면 0개라 안 지움(사람이 다시 써야 함)")
        for gid, matched in criteria_flagged:
            shown = ", ".join(f"'{_short(r, 40)}'" for r in matched)
            lines.append(f"  {gid}: {shown}  ⚠완료기준이 전체CI뿐 — 사람이 다시 써야 함")

    lines.append("")
    n_p, n_h, n_d = len(by_kind["product"]), len(by_kind["hardening"]), len(by_kind["decision"])
    summary = f"요약: product {n_p}(검토 필요 {n_p}) · hardening {n_h} · decision {n_d}"
    if already_classified:
        summary += f" · 이미 분류됨(스킵) {already_classified}"
    summary += f" — 완료기준에서 제거될 항목 {removed_total}건"
    lines.append(summary)
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(prog="ksi-goals-migrate")
    ap.add_argument("--dir", required=True, help="프로젝트 경로(.ksi/goals.json 위치)")
    ap.add_argument("--apply", action="store_true",
                     help="실제로 goals.json을 고친다(기본은 dry-run — 아무것도 안 씀)")
    args = ap.parse_args()

    kdir, gp, lp = ksi_goals.paths(args.dir)
    if not os.path.isdir(kdir):
        sys.exit(f"'.ksi' 없음: {kdir} — 경로 확인 또는 먼저 ksi-goals.py init")

    # ksi-goals.py의 락 관례 재사용 — dry-run도 잡는다(동시 다른 프로세스의 load~save와 겹치는 읽기를
    # 막아 계획 계산이 반쪽짜리 상태를 보지 않게).
    lockfile = open(os.path.join(kdir, "goals.lock"), "w")
    ksi_goals._lock_ex(lockfile)
    try:
        data = ksi_goals.load(gp)
        by_kind, criteria_removals, criteria_flagged, already_classified = plan(data)
        print(render_report(data["project"], by_kind, criteria_removals, criteria_flagged, already_classified))

        if not args.apply:
            print("\n(dry-run — goals.json 미변경. 반영하려면 --apply)")
            return

        ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        backup = f"{gp}.premigrate-{ts}"
        shutil.copy2(gp, backup)

        for kind, items in by_kind.items():
            for g, reason in items:
                g["kind"] = kind
                # verification_requested는 건드리지 않는다 — effective_verification()이 kind 기본값으로 재계산.
                ksi_goals.log(lp, "kind_migrated", g["id"], kind=kind, reason=reason)

        by_id = {g["id"]: g for g in data["goals"]}
        for gid, removed, kept in criteria_removals:
            by_id[gid]["completion_criteria"] = kept
            ksi_goals.log(lp, "criteria_migrated", gid, removed=removed)
        for gid, matched in criteria_flagged:
            # goals.json은 안 건드린다(원본 유지) — 사람이 다시 써야 한다는 사실만 ledger에 남긴다.
            ksi_goals.log(lp, "criteria_review_needed", gid, matched=matched,
                          note="완료기준이 전체CI뿐이라 지우면 0개로 감 — 안 지움, 사람이 다시 써야 함")

        ksi_goals.log(lp, "goals_migrated", None, project=data["project"], backup=backup,
                      product=len(by_kind["product"]), hardening=len(by_kind["hardening"]),
                      decision=len(by_kind["decision"]), already_classified=already_classified,
                      criteria_removed=sum(len(r[1]) for r in criteria_removals),
                      criteria_flagged=len(criteria_flagged))
        ksi_goals.save(gp, data)
        print(f"\n✓ 적용 완료 — 백업: {backup}")
    finally:
        ksi_goals._unlock(lockfile)
        lockfile.close()


if __name__ == "__main__":
    main()
