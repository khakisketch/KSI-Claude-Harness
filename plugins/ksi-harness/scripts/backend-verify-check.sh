#!/usr/bin/env bash
# Stop hook: 이 세션에서 백엔드 상태전이/테스트 코드(.py 중 tests·alembic·migrations·services·main)를
# '직접' 수정했는데 '완료'하려 할 때, 'green ≠ 작동'을 1회 알린다(시각 검증 게이트의 백엔드 대응물).
# **비차단**: systemMessage로 사용자에게 보이기만 하고 완료를 막지 않는다(ui-render-check.sh와 동형).
# - 프론트 ui-render-check.sh의 짝: 프론트=시각 확인 넛지, 백엔드=동작 검증 넛지.
#   ruff 훅은 .py 저장마다 '정적 lint'만 자동 주입한다 — 픽스처가 종단상태를 직접 주입해 실제 flow를
#   우회하는 가짜 green, SQLite-테스트/PG-프로덕션 dialect 분기는 ruff로 안 잡힌다. 그 공백을 완료 전 넛지.
# - 방어 골격은 ui-render-check.sh를 통째로 재사용(거짓양성·무한루프 정교 차단):
#   ① transcript: 메인 루프 직접 편집 + 이 세션의 서브에이전트/workflow 편집(사이드카 스캔).
#   ② git 교차: git diff HEAD + untracked 의 실제 미커밋 파일만 — 이미 커밋한 과거는 제외.
#   ③ compaction 경계 이후 편집만(요약 후 이전 세션 기록 오발 방지).
#   ④ 발화 조건 추가 협소화: 미커밋 .py 중 'tests/·test_*·alembic/·migrations/·services/·main.py'만.
#      순수 util·스키마·설정만 고친 세션엔 침묵(과발화 방지 — .py는 .tsx보다 변경 빈도가 훨씬 높다).
# - 루프 방지: stop_hook_active면 통과. transcript 없음/파싱 오류/비-git면 graceful 통과(세션 안 깸).
set -uo pipefail

input="$(cat)"

python3 - "$input" <<'PY' 2>/dev/null || exit 0
import sys, json, os

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
except Exception:
    sys.exit(0)

# 이미 이 훅이 띄운 continuation이면 더 막지 않는다(무한루프 방지)
if d.get("stop_hook_active"):
    sys.exit(0)

tp = d.get("transcript_path") or ""
if not tp or not os.path.exists(tp):
    sys.exit(0)

EXTS = (".py",)
EDIT_TOOLS = {"Edit", "Write", "MultiEdit"}
changed = set()

# 효율(0.8.3): 값싼 git 게이트를 비싼 transcript/사이드카 파싱보다 먼저 — 미커밋 .py가 하나도 없으면
# transcript 전체 파싱을 통째로 건너뛴다(관련 미커밋 0인 흔한 Stop에서 O(transcript) 비용 제거). git 불가면 종전대로 진행(graceful).
import subprocess

cwd = d.get("cwd") or os.getcwd()


def _git(args):
    try:
        r = subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True, timeout=5)
        return r.stdout.splitlines() if r.returncode == 0 else None
    except Exception:
        return None


_diff = _git(["diff", "--name-only", "HEAD"])
_untracked = _git(["ls-files", "--others", "--exclude-standard"])
_root = _git(["rev-parse", "--show-toplevel"])
git_ok = _diff is not None and _untracked is not None and bool(_root)
uncommitted = None
if git_ok:
    _exts_rels = [r for r in (*_diff, *_untracked) if r.strip() and r.endswith(EXTS)]
    if not _exts_rels:
        sys.exit(0)  # 미커밋 .py 없음 → 파싱 불필요, 조기 종료(git-first)
    base = _root[0]
    uncommitted = {
        os.path.normcase(os.path.normpath(os.path.join(base, rel)))
        for rel in _exts_rels
    }

# 1) 전체 레코드를 먼저 읽는다(compaction 경계를 알아야 그 이후만 보기 때문).
try:
    records = []
    with open(tp, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except Exception:
                records.append(None)
except Exception:
    sys.exit(0)

# 2) 마지막 compaction 경계 이후만 본다.
start = 0
for i, rec in enumerate(records):
    if not isinstance(rec, dict):
        continue
    if rec.get("isCompactSummary") or rec.get("compactMetadata"):
        start = i + 1


# 3) tool_use Edit/Write 블록에서 .py 편집 파일 경로를 changed에 모으는 헬퍼.
def _collect(recs):
    for rec in recs:
        if not isinstance(rec, dict):
            continue
        content = None
        m = rec.get("message")
        if isinstance(m, dict):
            content = m.get("content")
        if content is None:
            content = rec.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") != "tool_use":
                continue
            if block.get("name") not in EDIT_TOOLS:
                continue
            inp = block.get("input") or {}
            fp = inp.get("file_path") or ""
            if isinstance(fp, str) and fp.endswith(EXTS):
                changed.add(fp)


# 3a) 경계 이후의 메인 루프 직접 편집.
try:
    _collect(records[start:])
except Exception:
    sys.exit(0)

# 3b) 이 세션의 서브에이전트/workflow 편집도 포함(사이드카 스캔).
import glob

try:
    if tp.endswith(".jsonl"):
        sub_root = os.path.join(tp[:-6], "subagents")
        if os.path.isdir(sub_root):
            for jf in glob.glob(os.path.join(sub_root, "**", "agent-*.jsonl"), recursive=True):
                try:
                    recs = []
                    with open(jf, "r", encoding="utf-8") as sf:
                        for line in sf:
                            line = line.strip()
                            if not line:
                                continue
                            try:
                                recs.append(json.loads(line))
                            except Exception:
                                pass
                    _collect(recs)
                except Exception:
                    continue
except Exception:
    pass

if not changed:
    sys.exit(0)

# 4) git 미커밋 .py 변경과 교차 — uncommitted는 위(git-first)에서 이미 계산. git 불가면 graceful 통과.
#    normcase: Windows NTFS는 대소문자 무시라 케이스가 갈리면 교차가 공집합이 되는 거짓음성 — normcase로 케이스폴드(POSIX no-op).
if not git_ok or uncommitted is None:
    sys.exit(0)
changed = {os.path.normcase(os.path.normpath(p)) for p in changed} & uncommitted

if not changed:
    sys.exit(0)

# 4b) 발화 조건 협소화 — 상태전이/테스트 경로만(순수 util·스키마·설정엔 침묵).
def _is_interesting(p):
    norm = p.replace("\\", "/")
    base_name = os.path.basename(norm)
    if base_name.startswith("test_") or base_name.endswith("_test.py"):
        return True
    for seg in ("/tests/", "/alembic/", "/migrations/", "/services/", "/crud/", "/repositories/", "/routers/", "/endpoints/"):
        if seg in norm:
            return True
    if base_name in ("main.py", "conftest.py", "models.py", "crud.py", "service.py", "router.py", "routes.py"):
        return True
    return False


interesting = {p for p in changed if _is_interesting(p)}
n = len(interesting)
if n == 0:
    sys.exit(0)

# dedup (하네스 자가감사, CONFIRMED high): 동일 파일셋 반복 재넛지 차단 — ui-render-check와 동형.
# 키=정렬 fileset 해시(셋 변경 시 재넛지) + 세션당 하드캡 3회. 상세 근거는 ui-render-check.sh 주석 참조.
import hashlib, glob as _glob, tempfile
sid = d.get("session_id", "") or "nosession"
fs_hash = hashlib.sha1("\n".join(sorted(interesting)).encode()).hexdigest()[:8]
# Windows 이식성(2026-07-18): os.getuid()는 POSIX 전용이라 Windows Python이면 AttributeError로 훅이 발화 직전
# 죽어 영영 침묵했다(stderr는 2>/dev/null에 은폐). /tmp도 Windows Python에선 C:\tmp로 오해석 →
# gettempdir()(POSIX=TMPDIR//tmp·Win=%TEMP%) + getuid 폴백으로 교체(POSIX 동작 불변).
sent_dir = os.path.join(tempfile.gettempdir(), f"claude-{getattr(os, 'getuid', lambda: 0)()}")
sent = os.path.join(sent_dir, f"backendverify-nudge-{sid}-{fs_hash}")
try:
    os.makedirs(sent_dir, exist_ok=True)
    if os.path.exists(sent):
        sys.exit(0)
    if len(_glob.glob(f"{sent_dir}/backendverify-nudge-{sid}-*")) >= 3:
        sys.exit(0)
    open(sent, "w").close()
except Exception:
    pass

msg = (
    "상태전이/테스트 파일 " + str(n) + "개 수정됨 — green이 실제 동작인지 한 번 볼 시점입니다"
    "(캐시 클린 재현 · 픽스처가 종단상태를 직접 주입하지 않았나 · 테스트 DB와 운영 DB dialect 차이)."
)
print(json.dumps({"systemMessage": msg}, ensure_ascii=False))
sys.exit(0)
PY
exit 0
