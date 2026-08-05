#!/usr/bin/env bash
# PostToolUse hook (Edit|Write|MultiEdit): 화면·route 파일을 건드리면 "이 작업의 ui_change가 뭔지 분류하라"를
# 파일당 1회 상기시킨다(비차단).
#
# 왜 필요한가: 기존 UI 장치는 전부 **Stop 시점**에 뜬다(ui-render-check.sh = 완료 직전 "렌더 봤나").
# 그건 "다 만들고 나서야 의도와 다른 화면인 걸 알고 통째로 다시 만든다"는 문제를 못 막는다 — 그 시점엔
# 버려질 polish가 이미 다 만들어져 있다. 이 훅은 **만들기 시작할 때** 켜져서 worker.md의
# `ui_change: none|minor|checkpoint` 계약을 상기시킨다.
#
# 왜 훅인가(스킬이 아니라): 모델이 스스로 "지금이 그 절차를 부를 때다"를 판단해야 하는 스킬은 실측상 안 불린다
# (`debug` 30일 호출 0회, 그걸 권하는 훅은 같은 기간 28회 발화). 시점 통제는 훅에 둔다.
#
# 판정은 이 훅이 하지 않는다 — **경로는 후보 신호일 뿐이고 checkpoint/minor 판정은 모델이 한다.**
# 그래서 메시지는 "멈춰라"가 아니라 "분류를 확인하라"다. minor면 그대로 계속 진행한다.
#
# diff 규모를 안 쓰는 이유: "몇 줄부터 대규모인가"에 방어 가능한 임계값이 없다. 대신 경로를 유일한 게이트로
# 두고 **파일당 1회 + 세션 하드캡 3회**로 소음을 묶었다. 오발 비용은 모델이 "minor, 계속 진행"이라고
# 한 줄 답하는 것뿐이고, 누락 비용은 화면을 통째로 다시 만드는 것이라 오발 쪽으로 기울였다.
#
# 확장자 게이트가 핵심 오탐 방어다: `routes/`·`views/`는 백엔드에도 흔하다(Express `routes/users.js`,
# Django views.py). 프론트 확장자(.tsx/.jsx/.vue/.svelte/.astro)를 요구해 그 전부를 구조적으로 배제한다.
set -uo pipefail

input="$(cat)"
out="$(HOOK_INPUT="$input" python3 - <<'PY' 2>/dev/null
import json, os, re, sys, tempfile, glob, hashlib

SESSION_CAP = 3

try:
    d = json.loads(os.environ.get("HOOK_INPUT", "") or "{}")
except Exception:
    sys.exit(0)

ti = d.get("tool_input") or {}
path = ti.get("file_path") or ti.get("path") or ""
if not path:
    sys.exit(0)

norm = path.replace("\\", "/")
base = os.path.basename(norm)

# 프론트 확장자만 — 이게 백엔드 routes/·views/ 오탐의 구조적 방어선이다.
if not norm.endswith((".tsx", ".jsx", ".vue", ".svelte", ".astro")):
    sys.exit(0)

# 명시적 제외 — 화면이 아니거나 검사·생성물인 것.
EXCLUDE_SEG = (
    "/components/ui/",   # shadcn 류 프리미티브 — 화면이 아니라 부품
    "/node_modules/", "/.next/", "/dist/", "/build/", "/out/", "/generated/", "/__generated__/",
    "/scratchpad/",      # 다른 훅과 동일 범위
)
if any(seg in f"/{norm.lstrip('/')}" for seg in EXCLUDE_SEG):
    sys.exit(0)
if re.search(r"\.(test|spec|stories)\.[jt]sx?$|\.stories\.(svelte|vue)$", base):
    sys.exit(0)
if base.startswith("_generated") or ".gen." in base:
    sys.exit(0)

# Next.js API route는 화면이 아니다(pages/api/**). app router의 route.ts는 위 확장자 게이트에서 이미 걸러진다.
if "/pages/api/" in f"/{norm}" or norm.startswith("pages/api/"):
    sys.exit(0)

# 화면·route 후보 신호. 경로가 유일한 게이트다.
SCREEN_RE = re.compile(
    r"(^|/)app/.*/(page|layout|template|default|error|loading|not-found)\.[jt]sx$"  # Next.js app router
    r"|(^|/)app/(page|layout|template|error|loading|not-found)\.[jt]sx$"
    r"|(^|/)pages/"          # Next.js pages router (api는 위에서 제외)
    r"|(^|/)screens?/"       # React Native·모바일 관습
    r"|(^|/)views?/"         # Vue·일반 MVC 프론트
    r"|(^|/)routes/"         # Remix·SvelteKit (프론트 확장자 요구로 Express 배제됨)
    r"|(^|/)(page|layout)\.(vue|svelte|astro)$"
    r"|(^|/)\+(page|layout)\.svelte$"   # SvelteKit
    r"|(^|/)(dashboard|onboarding)/",   # 구조가 통째로 걸리는 대표 화면군
    re.IGNORECASE,
)
m = SCREEN_RE.search(norm)
if not m:
    sys.exit(0)

# dedup: 키는 파일 경로 — 같은 화면을 계속 고칠 땐 1회만. 세션 하드캡 3회(여러 화면을 만들어도 도배하지 않게).
sid = d.get("session_id") or "nosession"
uid = getattr(os, "getuid", lambda: 0)()
sent_dir = os.path.join(tempfile.gettempdir(), f"claude-{uid}")
key = hashlib.sha1(norm.encode("utf-8", "replace")).hexdigest()[:12]
sent = os.path.join(sent_dir, f"uicheckpoint-{sid}-{key}")
try:
    os.makedirs(sent_dir, exist_ok=True)
    if os.path.exists(sent):
        sys.exit(0)
    if len(glob.glob(os.path.join(sent_dir, f"uicheckpoint-{sid}-*"))) >= SESSION_CAP:
        sys.exit(0)
    open(sent, "w").close()
except Exception:
    pass

msg = (
    f"`{base}`는 화면·route 후보입니다(비차단 넛지, 파일당 1회 — 매칭: \"{m.group(0)}\"). "
    "이 작업의 `ui_change`를 확인하세요. "
    "**checkpoint**(신규 화면·route · 기존 화면의 대규모 레이아웃 변경 · 정보 우선순위나 정보구조 변경 · "
    "주요 사용자 동선 변경 · 대시보드 구조 변경)라면 **화면 골격 · 대표 데이터 · 주요 컴포넌트 배치 · "
    "최소 렌더 확인까지만** 하고, 사용자가 화면을 보고 방향을 확정하기 전에 전체 동작 구현·세부 polish·"
    "반응형 완성으로 넘어가지 마세요. "
    "**minor**(문구·색상·간격·아이콘·작은 기존 컴포넌트 수정 · 기존 화면 패턴 그대로 복제)라면 "
    "그대로 계속 진행하세요 — 이 넛지 때문에 사용자에게 상신하지 않습니다."
)
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": msg}}, ensure_ascii=False))
PY
)"
[ -n "${out:-}" ] && printf '%s\n' "$out"
exit 0
