#!/usr/bin/env python3
"""ksi-goals — durable goal-ledger 상태 헬퍼 (green≠작동의 멀티세션화).

OMX ultragoal 패턴 포팅: 프로젝트별 .ksi/{goals.json(상태), ledger.jsonl(append-only 이벤트)}.
완료는 자기신고가 아니라 evidence gate(reviewer 검증) 통과로만 인정 — gate refuted면 in_progress 유지.
완료가 나중에 조기였다고 드러나면 invalidate → false_positive_complete + 재오픈.

상태기계: proposed → in_progress ⇄ blocked → (gate pass) completed → (invalidate) false_positive_complete → 재오픈
          proposed/in_progress/blocked → abandoned  (completed·false_positive_complete·abandoned는 abandon 불가 — ALLOWED 참조)

이 스크립트는 '상태 I/O'만 결정론적으로 한다. evidence gate의 *판정*(reviewer adversarial 검증)은
/goals 스킬이 오케스트레이션하고, 그 결과만 `gate` 명령으로 기록한다(헬퍼는 reviewer를 부르지 않음).
코드 강제: 증거 없는 pass 불가 · pass엔 --reviewer/--evidence-ref 필수(자기선언 차단) · 전이 가드(ALLOWED — completed는 invalidate로만) · refuted/degraded는 증거 클리어 · id 형식검증(shell-inject 표면 축소).
가정: .ksi/goals.lock 배타락으로 load~save 구간을 프로세스 간 직렬화 — 동시 invocation의 lost-update를 방지
      (POSIX=fcntl.flock · Windows=msvcrt.locking · 둘 다 없으면 best-effort no-op. NFS 등 비POSIX 락 환경은 미보장).

사용: ksi-goals.py <command> [opts]   (CWD의 .ksi/ 대상, --dir로 변경)
"""
import argparse
import datetime
import json
import os
import re
import sys

# --- cross-platform 파일락: fcntl은 POSIX 전용이라 Windows Python에서 `import fcntl`이
#     ModuleNotFoundError로 스크립트 전체를 죽였다(goal-ledger가 Windows에서 통째로 무력). 플랫폼별로 분기하되
#     동작(load~save 직렬화)은 불변. 어느 것도 없으면 락을 포기하지 말고 best-effort no-op(단일 사용자 dev에선 충분).
try:
    import fcntl

    def _lock_ex(f):
        fcntl.flock(f, fcntl.LOCK_EX)

    def _unlock(f):
        fcntl.flock(f, fcntl.LOCK_UN)
except ImportError:  # Windows
    try:
        import msvcrt

        def _lock_ex(f):
            # msvcrt.locking은 현재 위치부터 nbytes 잠금(EOF 초과 허용). 블로킹 재시도 후 실패 시 예외 — 짧은 임계구역이라 수용.
            try:
                f.write("x")
                f.flush()
                f.seek(0)
            except Exception:
                pass
            try:
                msvcrt.locking(f.fileno(), msvcrt.LK_LOCK, 1)
            except OSError:
                pass  # 락 획득 실패(경합/재시도 소진) — 진행은 하되 직렬화 미보장(best-effort)

        def _unlock(f):
            try:
                f.seek(0)
                msvcrt.locking(f.fileno(), msvcrt.LK_UNLCK, 1)
            except OSError:
                pass
    except ImportError:  # 최후 폴백 — 락 없음(best-effort)
        def _lock_ex(f):
            pass

        def _unlock(f):
            pass


# goal/risk id 형식 — 쉘 명령에 보간되는 값이라 메타문자를 원천 차단(오케스트레이터가 인용해도 등록 시점 검증이 방어선).
# \Z(문자열 끝)로 앵커 — `$`는 Python re에서 후행 개행 1개를 허용(id 'G1\n' 통과)하는 gotcha가 있어 개행 주입 표면이 남는다.
ID_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_.-]{0,63}\Z")


def _check_id(gid, kind="goal"):
    if not ID_RE.match(gid or ""):
        sys.exit(f"{kind} id '{gid}' 형식 위반 — 영문자로 시작, 영숫자/_/-/. 만, 64자 이내(shell-inject 방지)")


STATES = ("proposed", "in_progress", "blocked", "completed", "false_positive_complete", "abandoned")
MARK = {"completed": "✓", "false_positive_complete": "✗재오픈", "abandoned": "—",
        "blocked": "⏸", "in_progress": "▶", "proposed": "·"}
# 허용 전이(현재상태 → 명령). 이 외엔 거부 — completed는 invalidate로만 빠져나간다(가짜완료 감사추적 우회 차단).
ALLOWED = {
    # start는 in_progress에서도 허용(idempotent) — goals-run.js가 재시도마다 start를 재호출하는데(refuted 후 목표가
    # in_progress로 남음) 이를 거부하면 자율 루프가 매 재시도에서 헛발화 에러를 냈다. start는 status만
    # in_progress로 (재)설정하고 evidence/attempt를 건드리지 않아 재실행이 무해하다.
    "start": ("proposed", "blocked", "in_progress"),
    "block": ("in_progress",),
    "attempt": ("in_progress",),
    "gate": ("in_progress",),
    "invalidate": ("completed",),
    "abandon": ("proposed", "in_progress", "blocked"),
}


def now():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def paths(d):
    k = os.path.join(d, ".ksi")
    return k, os.path.join(k, "goals.json"), os.path.join(k, "ledger.jsonl")


def state_path(d):
    return os.path.join(d, ".ksi", "state.json")


def git_head(d):
    """프로젝트 dir의 현재 git HEAD 짧은 sha(없으면 None) — state freshness 스탬프용(전체 폴백)."""
    import subprocess
    try:
        r = subprocess.run(["git", "-C", d, "rev-parse", "--short", "HEAD"],
                           capture_output=True, text=True, timeout=5)
        return r.stdout.strip() if r.returncode == 0 else None
    except Exception:
        return None


def git_module_sha(d, module):
    """모듈 경로에 한정된 마지막 커밋 sha — 모듈별 freshness(전체 HEAD 비교의 과탐 교정).
    module이 실제 경로가 아니거나(논리 모듈명) 이력이 없으면 None → 호출측이 전체 HEAD 폴백."""
    import subprocess
    if not module or not str(module).strip():
        return None
    try:
        r = subprocess.run(["git", "-C", d, "log", "-1", "--format=%h", "--", str(module).strip()],
                           capture_output=True, text=True, timeout=5)
        sha = r.stdout.strip()
        return sha if (r.returncode == 0 and sha) else None
    except Exception:
        return None


def git_module_dirty(d, module):
    """모듈 경로에 커밋 안 된 변경(staged/unstaged/untracked)이 있으면 True — HEAD가 안 바뀐 작업트리 변경도 stale로 잡음."""
    import subprocess
    if not module or not str(module).strip():
        return False
    try:
        r = subprocess.run(["git", "-C", d, "status", "--porcelain", "--", str(module).strip()],
                           capture_output=True, text=True, timeout=5)
        return r.returncode == 0 and bool(r.stdout.strip())
    except Exception:
        return False


def load(gp):
    if not os.path.exists(gp):
        sys.exit("'.ksi/goals.json' 없음 — 먼저 `ksi-goals.py init`")
    with open(gp, encoding="utf-8") as f:
        return json.load(f)


def save(gp, data):
    data["updated_at"] = now()
    tmp = gp + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, gp)


def log(lp, event, goal=None, **kw):
    rec = {"ts": now(), "event": event}
    if goal:
        rec["goal"] = goal
    rec.update(kw)
    with open(lp, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


def find(data, gid):
    for g in data["goals"]:
        if g["id"] == gid:
            return g
    sys.exit(f"goal '{gid}' 없음")


def new_goal(gid, title, criteria=None, parent=None):
    return {
        "id": gid, "title": title, "completion_criteria": criteria or [],
        "status": "proposed", "attempt": 1, "evidence": None, "verdict": None,
        "invalidation_reason": None, "parent": parent, "blocked_by": None,
        "ungated_attempts": 0,
        "created_at": now(), "updated_at": now(),
    }


def build_parser():
    p = argparse.ArgumentParser(prog="ksi-goals")
    p.add_argument("--dir", default=".")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("init").add_argument("--project", default=None,
                                         help="미지정 시 --dir 기준으로 실행 시점에 계산(CWD 고정 금지)")

    st = sub.add_parser("status")
    st.add_argument("--brief", action="store_true")
    st.add_argument("--json", action="store_true", help="기계판독 — goals-run.js 등 오케스트레이터용")

    rg = sub.add_parser("register")
    rg.add_argument("--id", required=True)
    rg.add_argument("--title", required=True)
    rg.add_argument("--criteria", default="", help="완료기준 ; 로 구분")
    rg.add_argument("--parent", default=None)

    sub.add_parser("start").add_argument("--id", required=True)

    bl = sub.add_parser("block")
    bl.add_argument("--id", required=True)
    bl.add_argument("--reason", required=True)

    at = sub.add_parser("attempt")
    at.add_argument("--id", required=True)
    at.add_argument("--evidence", required=True)

    ga = sub.add_parser("gate")
    ga.add_argument("--id", required=True)
    ga.add_argument("--verdict", required=True, choices=("pass", "refuted", "degraded"))
    ga.add_argument("--note", default="")
    ga.add_argument("--reviewer", default=None,
                     help="검증 주체 식별자(예: reviewer subagent) — verdict pass 시 필수(자기선언 pass 차단)")
    ga.add_argument("--evidence-ref", default=None,
                     help="증거 아티팩트 경로/transcript id — verdict pass 시 필수")

    iv = sub.add_parser("invalidate")
    iv.add_argument("--id", required=True)
    iv.add_argument("--reason", required=True)
    iv.add_argument("--reopen", default="", help="새 goal들 id:title;id:title")

    ab = sub.add_parser("abandon")
    ab.add_argument("--id", required=True)
    ab.add_argument("--reason", required=True)
    # durable '프로젝트 두뇌'(프로젝트 두뇌): 모듈별 '무엇이 있나' 상태.
    # goals=할 일, state=현황. audit 종점이 upsert(손편집 아님), git HEAD로 freshness.
    ss = sub.add_parser("state-set", help="모듈 상태 upsert(audit이 자동 호출) — green/risk/unknown")
    ss.add_argument("--module", required=True, help="경로/모듈명(예: backend/payments)")
    ss.add_argument("--status", required=True, choices=["green", "risk", "unknown"])
    ss.add_argument("--note", default="", help="한 줄 요약")
    ss.add_argument("--audit-ref", default="", help="근거(goal id·transcript·audit)")
    sh = sub.add_parser("state-show", help="프로젝트 두뇌 렌더 + freshness(git HEAD 대비)")
    sh.add_argument("--json", action="store_true")
    sh.add_argument("--brief", action="store_true")
    # risk 레코드(제품 안전망 — risk lifecycle): goal과 lifecycle이 다르다 —
    # risk는 fix(→goal)뿐 아니라 **accept(baseline로 수용, 근거 필수)**라는 종단이 있다.
    # goals.json 안 risks[]로(같은 lock·save 재사용, 린함). completion 술어를 오염시키지 않게 분리.
    ra = sub.add_parser("risk-add", help="제품 리스크 기록(open) — codebase-audit/release-risk 렌즈가 호출")
    ra.add_argument("--id", required=True)
    ra.add_argument("--title", required=True)
    ra.add_argument("--lens", required=True, choices=["role", "economic", "gaming", "time-axis", "db", "secret", "other"])
    ra.add_argument("--severity", required=True, choices=["critical", "high", "medium", "low"])
    ra.add_argument("--note", default="")
    rac = sub.add_parser("risk-accept", help="리스크를 baseline로 수용(근거 필수 — evidence-gate와 동형)")
    rac.add_argument("--id", required=True)
    rac.add_argument("--reason", required=True)
    rr = sub.add_parser("risk-resolve", help="리스크 해소(증거 필수)")
    rr.add_argument("--id", required=True)
    rr.add_argument("--evidence-ref", required=True)
    rro = sub.add_parser("risk-reopen", help="수용/해소된 리스크 재발(regression)")
    rro.add_argument("--id", required=True)
    rro.add_argument("--reason", required=True)
    rl = sub.add_parser("risk-list", help="open + accepted 분리 렌더")
    rl.add_argument("--json", action="store_true")
    rl.add_argument("--brief", action="store_true")
    return p


RISK_STATES = ("open", "accepted", "resolved", "regressed")
RISK_RANK = {"critical": 0, "high": 1, "medium": 2, "low": 3}
# risk도 goal처럼 전이 가드 — 임의 상태로 점프 금지(open→regressed·resolved→accepted 등 무의미 전이 차단).
#   accept  = open/regressed 인 리스크만 baseline 수용
#   resolve = open/regressed 인 리스크만 해소(증거 필수)
#   reopen  = accepted/resolved 된 리스크만 재발(regression)
RISK_ALLOWED = {
    "accepted": ("open", "regressed"),
    "resolved": ("open", "regressed"),
    "regressed": ("accepted", "resolved"),
}


def _risks(data):
    return data.setdefault("risks", [])


def _find_risk(data, rid):
    for r in _risks(data):
        if r["id"] == rid:
            return r
    return None


def cmd_risk_add(data, gp, lp, args):
    _check_id(args.id, "risk")
    if _find_risk(data, args.id):
        sys.exit(f"risk '{args.id}' 이미 존재")
    _risks(data).append({
        "id": args.id, "title": args.title, "lens": args.lens, "severity": args.severity,
        "status": "open", "note": args.note,
        # 전이별 근거를 분리 저장(예전엔 accept_reason 한 칸에 accept·reopen 사유가 섞여 감사추적이 뭉갰다).
        "accept_reason": None, "resolve_evidence": None, "reopen_reason": None,
        "previous_status": None,
        "created_at": now(), "updated_at": now(),
    })
    log(lp, "risk_add", args.id, lens=args.lens, severity=args.severity)
    save(gp, data)
    print(f"✓ risk 기록: {args.id} [{args.severity}/{args.lens}] (open — fix는 goal로 register, 수용은 risk-accept)")


def _risk_transition(data, gp, lp, rid, to, *, reason=None, evidence=None, reason_field="accept_reason"):
    r = _find_risk(data, rid)
    if not r:
        sys.exit(f"risk '{rid}' 없음")
    cur = r.get("status", "open")
    allowed = RISK_ALLOWED.get(to)
    if allowed and cur not in allowed:
        sys.exit(f"risk {rid}: '{cur}'→'{to}' 전이 불가 — 허용 출발상태: {', '.join(allowed)}")
    r["previous_status"] = cur
    r["status"] = to
    r["updated_at"] = now()
    if reason is not None:
        r[reason_field] = reason
    if evidence is not None:
        r["resolve_evidence"] = evidence
    # ledger에 근거/증거를 남긴다(예전엔 이벤트+id만 남아 '왜 수용/재발했나'가 원장에서 사라졌다).
    log(lp, f"risk_{to}", rid, from_status=cur, reason=reason, evidence_ref=evidence)
    save(gp, data)
    return r


def cmd_risk_list(data, as_json, brief):
    rs = _risks(data)
    by = {s: [r for r in rs if r["status"] == s] for s in RISK_STATES}
    if as_json:
        print(json.dumps({"risks": rs, "open": len(by["open"]) + len(by["regressed"]),
                          "accepted": len(by["accepted"]), "resolved": len(by["resolved"])}, ensure_ascii=False))
        return
    live = sorted(by["open"] + by["regressed"], key=lambda r: RISK_RANK.get(r["severity"], 9))
    if brief:
        parts = []
        if live:
            crit = sum(1 for r in live if r["severity"] in ("critical", "high"))
            parts.append(f"⚠미해소 리스크 {len(live)}" + (f"(critical/high {crit})" if crit else ""))
        if by["accepted"]:
            parts.append(f"수용 {len(by['accepted'])}")
        if parts:
            print("제품 리스크: " + " · ".join(parts))
        return
    print(f"# 제품 리스크 (미해소 {len(live)} · 수용 {len(by['accepted'])} · 해소 {len(by['resolved'])})")
    for r in live:
        print(f"  [{r['severity']:8}/{r['lens']}] {r['id']} {r['title']} — {r.get('note', '')}"
              + (" ↻regressed" if r["status"] == "regressed" else ""))
    for r in by["accepted"]:
        print(f"  [수용/{r['lens']}] {r['id']} {r['title']} — 근거: {r.get('accept_reason', '')}")


def cmd_state_set(sp, d, module, status, note, audit_ref):
    st = {"modules": {}}
    if os.path.exists(sp):
        try:
            with open(sp, encoding="utf-8") as f:
                st = json.load(f)
        except Exception:
            st = {"modules": {}}
    st.setdefault("modules", {})
    st["modules"][module] = {
        "status": status, "note": note, "audit_ref": audit_ref,
        # at_sha=전체 HEAD(폴백·하위호환) · at_module_sha=이 모듈 경로에 한정된 마지막 커밋(정밀 freshness).
        "at_sha": git_head(d), "at_module_sha": git_module_sha(d, module), "at": now(),
    }
    tmp = sp + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(st, f, ensure_ascii=False, indent=2)
    os.replace(tmp, sp)
    print(f"✓ state: {module} = {status}" + (f" ({note})" if note else ""))


def _state_load_with_freshness(sp, d):
    if not os.path.exists(sp):
        return None, None, []
    with open(sp, encoding="utf-8") as f:
        st = json.load(f)
    head = git_head(d)
    stale = []
    for mod, m in (st.get("modules") or {}).items():
        # 정밀: 모듈 경로에 한정된 sha가 있으면 그것만 비교(전체 HEAD 변경 하나로 모든 모듈이 stale 되던 과탐 교정)
        #       + 커밋 안 된 작업트리 변경도 stale로 잡음(예전엔 HEAD 안 바뀌면 놓쳤다).
        # 폴백: at_module_sha가 없으면(구 데이터·논리 모듈명) 종전 전체 HEAD 비교.
        at_mod = m.get("at_module_sha")
        if at_mod:
            cur_mod = git_module_sha(d, mod)
            if (cur_mod and cur_mod != at_mod) or git_module_dirty(d, mod):
                stale.append(mod)
        elif head and m.get("at_sha") and m["at_sha"] != head:
            stale.append(mod)
    return st, head, stale


def cmd_state_show(sp, d, as_json, brief):
    st, head, stale = _state_load_with_freshness(sp, d)
    if st is None:
        if as_json:
            print(json.dumps({"exists": False}))
        elif not brief:
            print("state.json 없음 — audit이 아직 두뇌를 안 채웠다(codebase-audit §6.5가 state-set 호출).")
        return
    mods = st.get("modules") or {}
    risk = [m for m, v in mods.items() if v.get("status") == "risk"]
    if as_json:
        print(json.dumps({"exists": True, "head": head, "modules": mods,
                          "risk": risk, "stale": stale}, ensure_ascii=False))
        return
    if brief:
        parts = [f"모듈 {len(mods)}"]
        if risk:
            parts.append(f"⚠risk {len(risk)}")
        if stale:
            parts.append(f"stale {len(stale)}(코드 변경 후 미재감사)")
        print("프로젝트 두뇌: " + " · ".join(parts))
        return
    print(f"# 프로젝트 두뇌 (현재 HEAD {head or '?'})")
    for mod, v in sorted(mods.items()):
        flag = " ⚠stale(재감사 필요)" if mod in stale else ""
        print(f"  [{v.get('status', '?'):7}] {mod} — {v.get('note', '')}"
              f" (감사시점 {v.get('at_sha', '?')}{flag})")
    if risk:
        print(f"\n  ⚠ risk 모듈 {len(risk)}: {', '.join(risk)}")
    if stale:
        print(f"  ⚠ stale {len(stale)}: 감사 후 HEAD가 바뀜 — 상태가 낡았을 수 있다(재감사 권장).")


def cmd_status(data, brief, as_json=False):
    cnt = {s: 0 for s in STATES}
    for x in data["goals"]:
        cnt[x["status"]] = cnt.get(x["status"], 0) + 1
    # in_progress 우선(이미 착수한 걸 이어가는 게 새로 시작하는 것보다 actionable) — proposed는 후순위.
    actionable = sorted(
        (x for x in data["goals"] if x["status"] in ("proposed", "in_progress")),
        key=lambda g: 0 if g["status"] == "in_progress" else 1,
    )
    nxt = f"{actionable[0]['id']} {actionable[0]['title']}" if actionable else "(없음)"
    if as_json:
        # goals-run.js가 소비: actionable 목록(다음 실행 대상)·counts·정지/완료 술어.
        # 술어 분리: 예전 `done`=actionable 0은 '전부 blocked'도 done=true라 '완료'로 오해됐다.
        #   - done       : actionable(proposed/in_progress) 0 → 실행 루프의 정지 조건(blocked는 사람 대기라 action 불가).
        #   - all_completed: 모든 목표가 completed(빈 원장은 false) → 진짜 '프로젝트 완료' 술어.
        #   - quiescent  : actionable 0이지만 blocked가 남음 → 멈췄으나 미완(사람 개입 대기).
        total = len(data["goals"])
        completed_n = cnt.get("completed", 0)
        print(json.dumps({
            "project": data["project"],
            "counts": cnt,
            "actionable": [
                {"id": x["id"], "title": x["title"], "status": x["status"],
                 "attempt": x.get("attempt", 1),
                 "criteria": x.get("completion_criteria", []),
                 "evidence": x.get("evidence", "")}
                for x in actionable
            ],
            "done": len(actionable) == 0,          # 실행 루프 정지 조건(action 가능 목표 없음)
            "blocked": cnt.get("blocked", 0),
            "all_completed": total > 0 and completed_n == total,   # 진짜 완료(전부 completed)
            "quiescent": len(actionable) == 0 and cnt.get("blocked", 0) > 0,  # 멈췄으나 blocked 잔존
        }, ensure_ascii=False))
        return
    if brief:
        parts = []
        if cnt["in_progress"]:
            parts.append(f"진행중 {cnt['in_progress']}")
        if cnt["proposed"]:
            parts.append(f"대기 {cnt['proposed']}")
        if cnt["blocked"]:
            parts.append(f"blocked {cnt['blocked']}")
        if cnt["false_positive_complete"]:
            parts.append(f"⚠가짜완료재오픈 {cnt['false_positive_complete']}")
        if parts:
            print(f"{data['project']} goal: " + " · ".join(parts) + f" — 다음: {nxt} (/goals)")
        return
    print(f"# {data['project']} — goal-ledger")
    for x in data["goals"]:
        print(f"  {MARK.get(x['status'], '?')} [{x['id']}] {x['title']}  ({x['status']}, attempt {x['attempt']})")
        if x.get("completion_criteria"):
            print(f"       기준: {' / '.join(x['completion_criteria'])}")
        if x.get("evidence"):
            print(f"       증거: {x['evidence']}")
        if x.get("invalidation_reason"):
            print(f"       ↳ 무효화: {x['invalidation_reason']}")
    print("\n  요약: " + " · ".join(f"{s}={cnt[s]}" for s in STATES if cnt[s]))
    print(f"  다음 actionable: {nxt}")


def main():
    args = build_parser().parse_args()
    kdir, gp, lp = paths(args.dir)

    # 동시성: load~save 구간을 .ksi/goals.lock 배타락으로 직렬화(POSIX=fcntl.flock · Windows=msvcrt.locking · _lock_ex 참조).
    # kdir이 아직 없고 init도 아니면(= .ksi 미초기화) 어차피 load()가 곧 sys.exit할 것이므로 락 불필요.
    lockfile = None
    if args.cmd == "init" or os.path.isdir(kdir):
        os.makedirs(kdir, exist_ok=True)
        # transient 락파일은 '.ksi는 커밋' 정책에서 git 노이즈가 되므로 자동 제외
        gi = os.path.join(kdir, ".gitignore")
        if not os.path.exists(gi):
            with open(gi, "w") as f:
                f.write("goals.lock\n")
        lockfile = open(os.path.join(kdir, "goals.lock"), "w")
        _lock_ex(lockfile)
    try:
        if args.cmd == "init":
            if os.path.exists(gp):
                print(f"이미 존재: {gp}")
                return
            project = args.project or os.path.basename(os.path.abspath(args.dir))
            log(lp, "init", project=project)
            save(gp, {"version": 1, "project": project, "updated_at": now(), "goals": [], "risks": []})
            print(f"✓ 초기화: {kdir}  (.gitignore에 넣지 말 것 — 목표 이력은 repo와 함께 커밋)")
            return

        data = load(gp)

        if args.cmd == "status":
            cmd_status(data, args.brief, getattr(args, "json", False))
            return

        if args.cmd == "state-set":
            cmd_state_set(state_path(args.dir), args.dir, args.module, args.status, args.note, args.audit_ref)
            return
        if args.cmd == "state-show":
            cmd_state_show(state_path(args.dir), args.dir, getattr(args, "json", False), args.brief)
            return

        if args.cmd == "risk-add":
            cmd_risk_add(data, gp, lp, args)
            return
        if args.cmd == "risk-accept":
            _risk_transition(data, gp, lp, args.id, "accepted", reason=args.reason)
            print(f"✓ risk {args.id} 수용(baseline) — 근거: {args.reason}")
            return
        if args.cmd == "risk-resolve":
            _risk_transition(data, gp, lp, args.id, "resolved", evidence=args.evidence_ref)
            print(f"✓ risk {args.id} 해소 — 증거: {args.evidence_ref}")
            return
        if args.cmd == "risk-reopen":
            _risk_transition(data, gp, lp, args.id, "regressed", reason=args.reason, reason_field="reopen_reason")
            print(f"↻ risk {args.id} 재발(regression) — {args.reason}")
            return
        if args.cmd == "risk-list":
            cmd_risk_list(data, getattr(args, "json", False), args.brief)
            return

        if args.cmd == "register":
            _check_id(args.id, "goal")
            if any(x["id"] == args.id for x in data["goals"]):
                sys.exit(f"goal '{args.id}' 이미 존재")
            if args.parent and not any(x["id"] == args.parent for x in data["goals"]):
                print(f"⚠ parent '{args.parent}' 미존재 — 참조만 기록(트리 검증 없음)")
            crit = [c.strip() for c in args.criteria.split(";") if c.strip()]
            data["goals"].append(new_goal(args.id, args.title, crit, args.parent))
            log(lp, "registered", args.id, status="proposed", parent=args.parent)
            save(gp, data)
            print(f"✓ 등록: {args.id}  (완료기준 {len(crit)}개 — gate가 이 기준 대비 검증)")
            return

        x = find(data, args.id)
        allowed = ALLOWED.get(args.cmd)
        if allowed and x["status"] not in allowed:
            extra = " (완료 목표는 invalidate로만 재오픈)" if x["status"] == "completed" else ""
            sys.exit(f"{args.id}: '{args.cmd}'은 상태 '{x['status']}'에서 불가 — 허용: {', '.join(allowed)}{extra}")

        if args.cmd == "start":
            x["status"] = "in_progress"
            x["blocked_by"] = None
            x["updated_at"] = now()
            log(lp, "started", args.id)
            save(gp, data)
            print(f"▶ {args.id} in_progress")
        elif args.cmd == "block":
            x["status"] = "blocked"
            x["blocked_by"] = args.reason
            x["updated_at"] = now()
            log(lp, "blocked", args.id, reason=args.reason)
            save(gp, data)
            print(f"⏸ {args.id} blocked")
        elif args.cmd == "attempt":
            ev = (args.evidence or "").strip()
            if not ev:
                sys.exit(f"{args.id}: 빈 evidence 불가 — 구체 산출물(테스트 출력·상태전이 trace·file:line)을 적어라")
            x["evidence"] = ev
            x["ungated_attempts"] = x.get("ungated_attempts", 0) + 1
            x["updated_at"] = now()
            log(lp, "completion_attempt", args.id, evidence=ev)
            save(gp, data)
            print(f"📋 {args.id} 완료 시도 기록 — 이제 evidence gate(reviewer 검증) 필요. 통과 시 `gate --verdict pass`")
            if x.get("completion_criteria"):
                print(f"   대조 기준: {' / '.join(x['completion_criteria'])}")
            if x["ungated_attempts"] > 3:
                print(f"⚠ {args.id}: gate 없이 attempt {x['ungated_attempts']}회 반복 — 게이트 우회 의심, reviewer 검증을 실제로 돌려라")
        elif args.cmd == "gate":
            if args.verdict == "pass":
                if not (x.get("evidence") or "").strip():
                    sys.exit(f"{args.id}: 증거 없이 pass 불가 — 먼저 `attempt --evidence` 후 reviewer 검증(증거 게이트 우회 금지)")
                if not (args.reviewer or "").strip() or not (args.evidence_ref or "").strip():
                    sys.exit(f"{args.id}: pass verdict엔 --reviewer(검증 주체)와 --evidence-ref(아티팩트 경로/transcript id) 필수 — 자기선언 pass 차단")
            evidence_snapshot = x.get("evidence")
            x["verdict"] = {"verdict": args.verdict, "note": args.note, "at": now(),
                             "reviewer": args.reviewer, "evidence_ref": args.evidence_ref}
            x["ungated_attempts"] = 0
            if args.verdict == "pass":
                x["status"] = "completed"
                msg = f"✓ {args.id} completed (evidence gate 통과)"
            elif args.verdict == "degraded":
                x["evidence"] = None  # 미검증 — 새 attempt 강제
                msg = f"⚠ {args.id} DEGRADED — verify 미완(rate-limit 등). completed 금지, in_progress 유지·재검증 필요"
            else:  # refuted
                x["status"] = "in_progress"
                x["attempt"] += 1
                x["evidence"] = None  # 기각된 증거는 재사용 불가 — 다음 pass가 새 attempt를 강제
                msg = f"✗ {args.id} gate refuted — in_progress 유지(attempt {x['attempt']}). 새 증거로 재검증: {args.note}"
            x["updated_at"] = now()
            log(lp, "gate_verdict", args.id, verdict=args.verdict, note=args.note,
                reviewer=args.reviewer, evidence_ref=args.evidence_ref)
            save(gp, data)
            print(msg)
            if x.get("completion_criteria"):
                print(f"   대조 기준: {' / '.join(x['completion_criteria'])}")
            if evidence_snapshot:
                print(f"   검증한 증거: {evidence_snapshot}")
        elif args.cmd == "invalidate":
            if x["status"] != "completed":
                sys.exit(f"{args.id}는 completed가 아니라 invalidate 불가(현재 {x['status']})")
            x["status"] = "false_positive_complete"
            x["invalidation_reason"] = args.reason
            x["updated_at"] = now()
            reopened = []
            skipped = []
            for part in (q for q in args.reopen.split(";") if q.strip()):
                nid, _, ntitle = part.partition(":")
                nid, ntitle = nid.strip(), ntitle.strip()
                if nid and not ID_RE.match(nid):
                    # reopen도 goal 생성 경로 — register/risk-add와 동일하게 id 형식검증(쉘 보간 표면 차단).
                    # 여기선 abort 대신 skip(무효화 자체는 진행) — 잘못된 id 하나가 전체 invalidate를 막지 않게.
                    skipped.append(nid + "(형식위반)")
                elif nid and not any(y["id"] == nid for y in data["goals"]):
                    data["goals"].append(new_goal(nid, ntitle or nid, parent=args.id))
                    reopened.append(nid)
                elif nid:
                    skipped.append(nid)
            log(lp, "false_positive_complete", args.id, reason=args.reason, reopened_as=reopened)
            save(gp, data)
            out = f"✗재오픈 {args.id} → false_positive_complete. 재오픈: {reopened or '(없음)'}"
            if not args.reopen.strip():
                out += "  ⚠ 재오픈 없이 무효화 — 후속 actionable 없음 주의"
            if skipped:
                out += f"  ⚠ 이미 존재해 스킵: {skipped}"
            print(out)
        elif args.cmd == "abandon":
            x["status"] = "abandoned"
            x["invalidation_reason"] = args.reason
            x["updated_at"] = now()
            log(lp, "abandoned", args.id, reason=args.reason)
            save(gp, data)
            print(f"— {args.id} abandoned")
    finally:
        if lockfile is not None:
            _unlock(lockfile)
            lockfile.close()


if __name__ == "__main__":
    main()
