#!/usr/bin/env bash
# PostToolUse hook (Edit|Write|MultiEdit): 같은 파일을 한 세션에서 8회째 편집하면 "추측-수정 루프에
# 빠진 것 아닌가"를 1줄 상기시킨다(비차단).
#
# 왜 훅인가: /debug 스킬은 "추측-수정 루프에 빠진 걸 **알아챘을 때** 꺼내는 도구"로 쓰여 있었고,
# 그래서 60일간 호출 0회였다. 자기 상태를 알아채야 켜지는 트리거는 켜지지 않는다 — 밖에서 사건이
# 켜주는 구조로 바꾼 것이 이 훅이다.
#
# 임계값 8의 근거(실측, transcript 400세션): (세션,파일) 편집 횟수 분포가 p50=2·p75=3·p90=5·p95=8.
# 8회는 상위 5.7%라 '이 파일에서 유난히 오래 헤매는 중'의 신호가 된다. 6회(9.2%)는 정상 작업까지
# 걸려 gate-nudge식 crying-wolf가 되고, 13회(1.8%)는 이미 늦다.
#
# dedup: 카운터가 정확히 8일 때만 출력 — 파일당 세션당 1회. 9회 이후는 침묵(같은 파일을 계속
# 고칠 때 매 편집마다 재주입하면 그 자체가 피로다).
set -uo pipefail

input="$(cat)"
out="$(HOOK_INPUT="$input" python3 - <<'PY' 2>/dev/null
import json, os, sys, tempfile, hashlib

THRESHOLD = 8

try:
    d = json.loads(os.environ.get("HOOK_INPUT", "") or "{}")
except Exception:
    sys.exit(0)

ti = d.get("tool_input") or {}
path = ti.get("file_path") or ti.get("path") or ti.get("notebook_path") or ""
if not path:
    sys.exit(0)

# 버릴 임시 파일은 세지 않는다(ruff-check.sh와 동일 범위 — 스크래치패드만).
if "/scratchpad/" in path.replace("\\", "/"):
    sys.exit(0)

sid = d.get("session_id") or "nosession"
uid = getattr(os, "getuid", lambda: 0)()
d_ = os.path.join(tempfile.gettempdir(), f"claude-{uid}", f"debugloop-{sid}")
key = hashlib.sha1(path.encode("utf-8", "replace")).hexdigest()[:16]
counter = os.path.join(d_, key)

try:
    os.makedirs(d_, exist_ok=True)
    n = 0
    if os.path.exists(counter):
        with open(counter) as f:
            n = int((f.read() or "0").strip() or 0)
    n += 1
    with open(counter, "w") as f:
        f.write(str(n))
except Exception:
    sys.exit(0)

if n != THRESHOLD:   # 정확히 임계값일 때만 — 파일당 세션당 1회
    sys.exit(0)

msg = (
    f"이 세션에서 {os.path.basename(path)}를 {THRESHOLD}번째 편집했습니다(비차단 넛지). "
    "원인을 알고 고치는 중이거나 계획된 다지점 편집이면 무시하세요. "
    "같은 증상에 대한 수정이 또 실패한 거라면 추측-수정 루프입니다 — "
    "**다음 Edit 전에 `/debug`를 호출해** 최소 재현 · 경쟁 가설 · 그 둘을 가르는 판별 실험을 먼저 적으세요. "
    "세 번째 추측성 수정을 바로 시작하지 마세요. "
    "확인할 것: ① 일관되게 재현되는 최소 케이스가 있나 ② 잘못된 값이 **처음** 나타나는 지점까지 거슬러 갔나 "
    "③ 가설을 한 문장으로 적고 그것만 반증하는 실험을 하고 있나. "
    "거기서도 안 잡히면 문제가 이 층이 아닐 수 있습니다(설계·데이터 모델·라이브러리 의심)."
)
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": msg}}, ensure_ascii=False))
PY
)"
[ -n "${out:-}" ] && printf '%s\n' "$out"
exit 0
