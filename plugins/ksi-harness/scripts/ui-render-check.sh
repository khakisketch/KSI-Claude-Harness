#!/usr/bin/env bash
# Stop hook: 이 세션에서 프론트엔드 화면 파일(.tsx/.jsx/.vue/.svelte/.css/.scss — 실제 EXTS는 코드가 SSOT)을 '직접' 수정했는데
# '완료'하려 할 때, 렌더를 봤는지 1회 알린다(시각 검증 게이트의 프론트 대응물).
# **비차단**: systemMessage로 사용자에게 보이기만 하고 완료를 막지 않는다 — 강제는 준수율을 올리는 대신
#   흐름을 끊고 보일러플레이트를 재주입해 실제 작업 품질을 깎았다(목표는 준수가 아니라 개발 결과물).
# - 3-훅 게이트 대칭: 백엔드=정적 lint(ruff, 자동 주입)+동작 넛지(backend-verify, Stop) / 프론트=시각+동선 넛지(이 훅, Stop).
# - 핵심: 막는 조건 = '이 세션 transcript의 Edit/Write/MultiEdit' ∩ 'git 미커밋 프론트 변경'.
#   ① transcript: 메인 루프 직접 편집 + 이 세션의 서브에이전트/workflow 편집(확장).
#      서브에이전트 편집은 메인 transcript에 안 잡히므로(isSidechain 0개), 세션 사이드카
#      <transcript_path 확장자 제거>/subagents/**/agent-*.jsonl 를 직접 스캔한다 — fan-out으로
#      .tsx를 고치는 핵심 운영경로(workflow 기본)에서 영영 침묵하던 구조적 거짓음성을 봉합.
#   ② git 교차(추가): git diff HEAD + untracked 에 실제 미커밋인 파일만 막는다 —
#      이미 커밋한 과거 화면은 제외. 구버전은 transcript만 봐서, 긴 세션에서 커밋 끝난 화면이
#      이후 모든 Stop마다 영구 오발했다(아래 ③ compaction 보정만으론 '요약 후 편집했지만
#      이미 커밋한' 경우를 못 거른다 — git 교차가 그 구멍을 메운다).
#   구버전이 봤던 git status(작업트리 전체)의 거짓양성(안 만진 화면 오발)도 함께 회피한다.
# - 컨텍스트 요약(compaction) 보정(추가): transcript jsonl은 compaction 후에도
#   같은 파일에 누적된다(이전 세션 기록이 그대로 남음). 따라서 '마지막 compaction 경계
#   (isCompactSummary 또는 compactMetadata 레코드) 이후'의 편집만 본다. 이게 없으면
#   요약으로 이어진 세션에서 이전 세션의 tsx 편집까지 잡혀 매 턴 오발한다(거짓양성).
# - 루프 방지: stop_hook_active면 통과. transcript 없음/파싱 오류면 graceful 통과(세션 안 깸).
set -uo pipefail

input="$(cat)"

python3 - "$input" <<'PY' 2>/dev/null || exit 0
import sys, json, os, re

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

EXTS = (".tsx", ".jsx", ".vue", ".svelte", ".css", ".scss")
EDIT_TOOLS = {"Edit", "Write", "MultiEdit"}
changed = set()

# 효율(0.8.3): 값싼 git 게이트를 비싼 transcript/사이드카 파싱보다 먼저 실행 — 미커밋 EXTS 파일이 하나도 없으면
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
        sys.exit(0)  # 미커밋 EXTS 파일 없음 → 파싱 불필요, 조기 종료(git-first)
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
                records.append(None)  # 자리 보존(인덱스 유지)
except Exception:
    sys.exit(0)

# 2) 마지막 compaction 경계를 찾는다. compaction 후 transcript는 같은 파일에 누적되므로,
#    그 경계 이후만 봐야 '이번(요약 이후) 세션'의 편집이다.
#    경계 마커: isCompactSummary == True 인 레코드, 또는 compactMetadata 키를 가진 레코드.
start = 0
for i, rec in enumerate(records):
    if not isinstance(rec, dict):
        continue
    if rec.get("isCompactSummary") or rec.get("compactMetadata"):
        start = i + 1

# 3) tool_use Edit/Write 블록에서 EXTS 편집 파일 경로를 changed에 모으는 헬퍼.
def _collect(recs):
    for rec in recs:
        if not isinstance(rec, dict):
            continue
        # assistant 메시지의 content 배열에서 tool_use 블록을 찾는다.
        # 포맷 차이를 흡수: rec["message"]["content"] 또는 rec["content"].
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

# 3b) 이 세션의 서브에이전트/workflow 편집도 포함(추가).
#     메인 transcript엔 서브에이전트 편집이 안 잡히므로(isSidechain 0개), 세션 사이드카
#     디렉토리 <transcript_path 확장자 제거>/subagents/**/agent-*.jsonl 를 직접 스캔한다.
#     이들은 '이 세션' 디렉토리에만 있어 cross-session 거짓양성이 구조적으로 없고,
#     아래 git 미커밋 교차가 이미 커밋된/stale 편집을 추가로 걸러준다(compaction 보정 불필요).
import glob

try:
    if tp.endswith(".jsonl"):
        sub_root = os.path.join(tp[:-6], "subagents")  # ".jsonl"(6자) 제거 = 세션 사이드카
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

# 4) git 미커밋 프론트 변경과 교차 — uncommitted는 위(git-first)에서 이미 계산. git 불가면 graceful 통과.
#    normcase: Windows NTFS는 대소문자 무시라 케이스가 갈리면 교차가 공집합이 되는 거짓음성 — normcase로 케이스폴드(POSIX no-op).
if not git_ok or uncommitted is None:
    sys.exit(0)
changed = {os.path.normcase(os.path.normpath(p)) for p in changed} & uncommitted

n = len(changed)
if n == 0:
    sys.exit(0)

# dedup (하네스 자가감사, CONFIRMED high): stop_hook_active는 같은 Stop 사이클 재진입만 막아
# 마라톤 세션에서 동일 파일셋에 같은 보일러플레이트가 최대 106회 재주입됐다(실측). 키는 세션 1회가 아니라
# '정렬된 fileset 해시' — 파일셋이 바뀌면(새 화면 편집) 정당하게 재넛지하고, 불변이면 침묵한다.
# 추가로 세션당 하드캡 3회: 파일셋이 계속 바뀌는 마라톤에서도 같은 종류의 넛지가 스크롤백을 도배하지 않게.
import hashlib, glob as _glob, tempfile
sid = d.get("session_id", "") or "nosession"
fs_hash = hashlib.sha1("\n".join(sorted(changed)).encode()).hexdigest()[:8]
# Windows 이식성(2026-07-18 실측): os.getuid()는 POSIX 전용이라 Windows Python이면 이 지점에서
# AttributeError로 훅 전체가 죽어 영영 침묵했다(stderr는 2>/dev/null에 은폐 — 발화 직전 크래시).
# /tmp 하드코딩도 Windows Python에선 C:\tmp로 풀린다. gettempdir()(POSIX=TMPDIR//tmp·Win=%TEMP%)
# + getuid 폴백으로 교체 — POSIX 동작은 불변.
sent_dir = os.path.join(tempfile.gettempdir(), f"claude-{getattr(os, 'getuid', lambda: 0)()}")
sent = os.path.join(sent_dir, f"uirender-nudge-{sid}-{fs_hash}")
try:
    os.makedirs(sent_dir, exist_ok=True)
    if os.path.exists(sent):
        sys.exit(0)
    if len(_glob.glob(f"{sent_dir}/uirender-nudge-{sid}-*")) >= 3:
        sys.exit(0)
    open(sent, "w").close()
except Exception:
    pass

msg = (
    "화면 파일 " + str(n) + "개 수정됨 — 렌더를 아직 안 봤다면 확인해 볼 시점입니다"
    "(레이아웃 변경이면 390·768·1440, 모달·팝오버는 연 상태로, 빈 DB로 한 번). 전 페이지면 /ui-audit."
)
print(json.dumps({"systemMessage": msg}, ensure_ascii=False))
sys.exit(0)
PY
exit 0
