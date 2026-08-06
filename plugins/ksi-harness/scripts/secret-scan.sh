#!/usr/bin/env bash
# PostToolUse hook: Edit/Write/MultiEdit 시 '민감 쓰기' 3종을 경고-only로 넛지한다(ruff-check.sh의 PostToolUse 짝).
#   (1) 하드코딩 시크릿(고신뢰 패턴) (2) 파괴적 migration DDL (3) ~/.claude/settings.json drift(model 키 재등장·effort 저하).
# - PostToolUse라 차단 불가 → additionalContext 경고만(ruff 훅과 동일 계약). 확인했거나 오탐이면 그대로 진행.
# - 오탐 최소화: *.example/*.sample/*.lock·lockfile·node_modules·~/.claude/hooks(자기 자신) 제외, 시크릿 대입형은 env-ref/placeholder 제외.
# - 입력(JSON)은 stdin으로 받는다 — Write는 파일 내용 전체가 입력에 실려 argv(MAX_ARG_STRLEN 128KB)를 넘길 수 있다.
# - 1h dedup: 같은 (파일+발견) 경고를 반복 주입하지 않는다(ruff 훅 sentinel 패턴 재사용).
set -uo pipefail

# 프로그램은 -c 인자(약 4KB, 한도 내), 큰 입력은 stdin으로 흘려보낸다. 프로그램 내부에 작은따옴표(')를 쓰지 않는다(\x27로 대체).
python3 -c '
import sys, json, os, re, hashlib, time, tempfile

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)

ti = d.get("tool_input", {}) or {}
fp = ti.get("file_path") or ti.get("path") or ti.get("notebook_path") or ""
if not fp or not os.path.isfile(fp):
    sys.exit(0)

tool = d.get("tool_name", "") or ""
old_s = ti.get("old_string") or ""
new_s = ti.get("new_string") or ""

home = os.path.expanduser("~")
npath = os.path.normpath(fp)
norm = fp.replace("\\", "/")
base = os.path.basename(fp)
low = base.lower()

findings = []

# ---------- (3) settings.json drift (정확 경로만) ----------
if npath == os.path.normpath(os.path.join(home, ".claude", "settings.json")):
    try:
        with open(fp, encoding="utf-8") as f:
            cfg = json.load(f)
        # model 키 경고 철회 — /model 세션선택이 settings.json에 값을 persist하는 정상 런타임 동작이라
        # 하드코딩 위반이 아니다(반복 재발은 이 메커니즘의 오진이었다). model은 런타임 소유라
        # 하네스 위생 대상이 아니다. effort 경고는 유효하므로 유지.
        # 주의: 이 파이썬은 python3 -c 홑따옴표 문자열로 전달된다 — 주석에도 아포스트로피 금지.
        eff = cfg.get("effortLevel")
        if eff is not None and eff not in ("high", "xhigh", "max"):
            findings.append("effortLevel=" + str(eff) + " — 코드작업 effort 하한은 high입니다(high/xhigh/max 권장).")
    except Exception:
        pass

# ---------- 시크릿·마이그레이션: 예시/락/노드모듈/훅자신/데이터·바이너리 제외 ----------
# 효율: 데이터/바이너리 확장자는 시크릿 정규식이 의미 없고 대용량이라 스캔 낭비 — 제외.
DATA_EXTS = (".csv", ".tsv", ".parquet", ".png", ".jpg", ".jpeg", ".gif", ".webp",
             ".pdf", ".zip", ".gz", ".tar", ".woff", ".woff2", ".ttf", ".ico", ".mp4",
             ".map", ".min.js", ".min.css")
is_excluded = (
    low.endswith((".example", ".sample", ".lock"))
    or low.endswith(DATA_EXTS)
    or low in ("package-lock.json", "yarn.lock", "pnpm-lock.yaml", "poetry.lock")
    or "/node_modules/" in norm
    or npath.startswith(os.path.normpath(os.path.join(home, ".claude", "hooks")))
)

if not is_excluded:
    # 효율: Edit/MultiEdit는 새로 추가된 텍스트(new_string)만 스캔 — 매 편집 전체(≤1MB) 재읽기 낭비 제거.
    # 신규 유입 시크릿/파괴적 DDL을 잡는 목적엔 added text로 충분. Write(전체 파일)만 파일을 읽는다.
    if tool in ("Edit", "MultiEdit") and (new_s or old_s):
        text = new_s
    else:
        try:
            with open(fp, encoding="utf-8", errors="replace") as f:
                text = f.read(1000000)
        except Exception:
            text = ""

    if text:
        # (1) 하드코딩 시크릿 — 고신뢰 패턴
        hits = []
        for name, pat in (
            ("AWS access key", r"AKIA[0-9A-Z]{16}"),
            ("Google API key", r"AIza[0-9A-Za-z_\-]{35}"),
            ("OpenAI/Anthropic-style key", r"\bsk-[A-Za-z0-9]{20,}"),
            ("Slack token", r"xox[baprs]-[A-Za-z0-9-]{10,}"),
            ("GitHub token", r"gh[pousr]_[A-Za-z0-9]{30,}"),
            ("Private key block", r"-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----"),
        ):
            if re.search(pat, text):
                hits.append(name)
        if re.search(r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}", text):
            hits.append("JWT(서명 토큰 — service_role 의심)")
        ENVREF = re.compile(r"(process\.env|os\.environ|getenv|import\.meta\.env|\$\{|<[^>]{1,40}>|your[_-]|x{3,}|changeme|example|placeholder|dummy|fake|test[_-]?key|\*\*\*|\.\.\.)", re.I)
        for m in re.finditer(r"(?i)(?<![A-Za-z0-9])(password|passwd|secret[_-]?key|secret|api[_-]?key|access[_-]?key|client[_-]?secret|auth[_-]?token|private[_-]?key)(?![A-Za-z0-9])\s*[:=]\s*[\x22\x27]([^\x22\x27\n]{8,})[\x22\x27]", text):
            if not ENVREF.search(m.group(2)):
                hits.append("하드코딩된 " + m.group(1) + " 값")
                break
        if hits:
            seen = []
            for h in hits:
                if h not in seen:
                    seen.append(h)
            findings.append("시크릿 의심: " + ", ".join(seen) + " — 비밀이 코드에 하드코딩됐는지 확인하고, 맞으면 환경변수/시크릿매니저로 옮기세요(push 전 — 되돌리기 어려움).")

        # (2) 파괴적 migration DDL
        if re.search(r"/(migrations|migrate|migration)/", norm) and low.endswith((".sql", ".py")):
            ddl = []
            if re.search(r"(?i)\bDROP\s+(TABLE|COLUMN)\b", text):
                ddl.append("DROP TABLE/COLUMN")
            if re.search(r"(?i)\bALTER\s+TABLE\b[\s\S]{0,80}\bDROP\b", text):
                ddl.append("ALTER...DROP")
            if re.search(r"(?i)\bRENAME\s+(TO|COLUMN|TABLE)\b", text):
                ddl.append("RENAME")
            # NOT NULL(DEFAULT 없음)은 기존 테이블 변경(ALTER)일 때만 위험 — 신규 CREATE TABLE의 NOT NULL은 정상.
            # 예전엔 CREATE TABLE ... NOT NULL도 파괴적으로 오표기: SET NOT NULL 또는 ALTER TABLE 문맥에서만 발화.
            if re.search(r"(?i)\bSET\s+NOT\s+NULL\b", text) or (
                re.search(r"(?i)\bALTER\s+TABLE\b[\s\S]{0,200}\bNOT\s+NULL\b", text)
                and not re.search(r"(?i)\bDEFAULT\b", text)
            ):
                ddl.append("NOT NULL(DEFAULT 없음)")
            if ddl:
                msg = "파괴적 마이그레이션 DDL: " + ", ".join(ddl) + "."
                if not re.search(r"(?i)(downgrade|rollback|def down|-- *down)", text):
                    msg += " 롤백/downgrade 경로가 안 보입니다."
                msg += " 마이그레이션=되돌리기 어려운 작업(대표자 결정 레인): 롤백·다운타임·기존데이터 영향을 확인하세요."
                findings.append(msg)

if not findings:
    sys.exit(0)

# 1h dedup (file+findings 해시) — 같은 경고 반복 주입 방지
key = hashlib.sha1((npath + "|" + "||".join(findings)).encode("utf-8", "replace")).hexdigest()
sentinel = os.path.join(tempfile.gettempdir(), "claude-secret-scan.last")  # Windows에서 /tmp→C:\tmp 오배치 방지(gettempdir=%TEMP%)
now = int(time.time())
seen = {}
try:
    with open(sentinel) as sf:
        for ln in sf:
            p = ln.split()
            if len(p) == 2:
                seen[p[0]] = int(p[1])
except Exception:
    pass
if key in seen and now - seen[key] < 3600:
    sys.exit(0)
seen[key] = now
seen = {k: v for k, v in seen.items() if now - v < 7200}
try:
    with open(sentinel, "w") as sf:
        for k, v in seen.items():
            sf.write(k + " " + str(v) + "\n")
except Exception:
    pass

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": "[민감 쓰기 점검] " + base + ":\n- " + "\n- ".join(findings)
            + "\n(경고만 — 차단 아님. 확인했거나 오탐이면 그대로 진행하세요.)"
    }
}))
' 2>/dev/null
exit 0
