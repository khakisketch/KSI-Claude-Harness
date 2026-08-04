#!/usr/bin/env bash
# PreToolUse(Bash) hook: outbound exfiltration 넛지 — pre-destructive-guard.sh가 '삭제·되돌리기 불가'만 보고
# secret/env/파일을 외부로 유출하는 패턴은 안 본다는 갭을 메운다. CLAUDE.md '## 신뢰 경계' 절의 실제 개입 지점.
# **경고형이지 하드블록이 아니다** — curl/wget 데이터 전송 자체는 정당한 배포·API 호출에서도 흔해 exit 2로
# 막으면 자율성을 훼손한다. 탐지 시 stderr 경고 1줄 + exit 0(항상). 판단은 여전히 모델·사용자 몫.
# 탐지 대상:
#   (1) curl/wget에 데이터 전송 플래그(-d/--data*/-F/--form/-T/--upload-file/wget --post-data 등)가 있고
#       동일 세그먼트에 민감 신호($…KEY/SECRET/TOKEN/PASSWORD/CREDENTIAL, .env, ~/.claude, ~/.ssh, id_rsa,
#       .aws/credentials, printenv, env |)가 함께 보이는 경우.
#   (2) curl/wget 결과를 셸 인터프리터로 파이프하는 RCE 패턴(curl ... | bash 등).
#   (3) env/printenv(환경변수 전체 덤프)를 curl/wget/nc/ssh로 파이프하는 경우.
#   (4)(A-2) scp/rsync 인자에 원격 목적지(user@host:)와 민감 신호가 함께 있는 경우 — curl류와 인자 형태가
#       달라(데이터 플래그가 아니라 파일 인자 자체가 전송 페이로드) 별도 로직. -i/-F/-e(rsync 원격 셸,
#       보통 `ssh -i ~/.ssh/id_rsa`)의 값은 정상 인증 수단이라 스캔 제외.
#   (5)(A-2) 민감파일을 cat/type으로 읽어 ssh/nc류로 파이프, 또는 ssh 표준입력을 민감파일로 리다이렉트
#       (`ssh host < .env`) — ssh는 scp/rsync와 달리 파일 인자로 전송하지 않아 파이프·리다이렉트 경로만 본다.
#       `-i ~/.ssh/id_rsa`(식별키 플래그)는 파이프·리다이렉트가 아니므로 안 걸린다.
#   (6)(A-3) curl/wget 요청에 리터럴 고신뢰 토큰(Bearer 뒤 20자+ 영숫자/기호, sk-/ghp_/AKIA/xox 등 알려진
#       접두사)이 박힌 경우 — 데이터 전송 플래그 유무와 무관(단순 GET 헤더도 포함). `Bearer $TOKEN`(변수 참조)·
#       `Bearer <TOKEN>`(placeholder)·`Bearer abc123`(20자 미만 짧은 예시)는 문자 클래스·길이로 제외.
# 오탐 억제: localhost/127.0.0.1/0.0.0.0 대상은 로컬 개발이라 제외. 데이터 전송 플래그가 아예 없는 단순
# GET·순수 다운로드(-O/-o)는 애초에 (1)에 안 걸린다(단 (6)은 별도로 걸릴 수 있음 — 리터럴 토큰 자체가 신호).
# 세그먼트 분리·래퍼 스트립(env/bash-c 재귀)은 pre-destructive-guard.sh와 동일 heuristic을 재사용 —
# 완전 셸 파서가 아니라 휴리스틱임을 인지(폐쇄 불가). (4)(5)는 qtoks(따옴표 보존 토큰)로 재분리해 naive
# 공백분리가 따옴표 묶음(`-e "ssh -i ~/.ssh/id_rsa"`)을 깨서 정상 인증까지 오탐하는 것을 막는다.
set -uo pipefail

input="$(cat)"
GUARD_INPUT="$input" python3 - <<'PY'
import json, os, re, shlex, sys

def main():
    try:
        d = json.loads(os.environ.get("GUARD_INPUT", "") or "{}")
    except Exception:
        return
    if d.get("tool_name") != "Bash":
        return
    cmd = (d.get("tool_input") or {}).get("command", "") or ""
    if not cmd:
        return

    warnings = []

    def warn(reason):
        warnings.append(reason)

    ENV_OPTS_WITH_ARG = ("-C", "-S", "-u", "--chdir", "--unset")
    SHELLS = ("bash", "sh", "zsh", "dash")
    INTERPRETERS = ("bash", "sh", "zsh", "dash", "python", "python3", "perl", "ruby", "node", "nodejs")
    # A-2: ssh 추가 — `env | ssh user@host '...'` 로 환경변수 전체를 원격 셸에 흘려보내는 것도
    # nc/curl과 동일한 위험(시크릿 전체 유출)이라 같은 파이프 판정에 포함시킨다.
    NET_TOOLS_FOR_ENV = ("curl", "wget", "nc", "ncat", "netcat", "ssh")
    # A-2: 민감파일을 읽어 원격으로 흘리는 파이프의 '읽기' 쪽 프로그램(cat/type) — 아래 ssh/nc 파이프 판정에서 사용.
    READ_TOOLS = ("cat", "type")

    SHORT_DATA_FLAGS = {"-d", "-F", "-T"}
    LONG_DATA_FLAGS = {
        "--data", "--data-ascii", "--data-binary", "--data-raw", "--data-urlencode",
        "--form", "--upload-file", "--post-data", "--post-file",
    }

    SENSITIVE_RE = re.compile(
        r"\$\{?[A-Z_]*(?:KEY|SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL)[A-Z_]*\}?"
        r"|\.env(?:\.[A-Za-z0-9_.-]+)?\b"
        r"|~/\.claude\b"
        r"|~/\.ssh\b"
        r"|id_rsa\b"
        r"|\.aws/credentials\b"
        r"|\bprintenv\b"
        r"|\benv\s*\|"
    )

    # A-3: $VAR 참조가 아니라 리터럴로 박힌 고신뢰 토큰 — Bearer 뒤 20자+ 영숫자/기호, 또는 알려진 접두사.
    # 길이 하한(20)과 문자 클래스(영숫자·-·_·.·=만 허용, `$`·`<`·공백 불허)로 `Bearer $TOKEN`·`Bearer <TOKEN>`·
    # `Bearer abc123` 같은 변수참조·placeholder·짧은 예시는 걸리지 않는다(오탐 억제 — 경고형이라 마찰 비용이 큼).
    # (?<![A-Za-z0-9_-]) — 접두사 앞 경계. 없으면 `task-`·`disk-`·`risk-`의 뒤쪽이 `sk-`로 매치돼
    # 평범한 URL(`/api/task-a1b2c3…`)까지 시크릿으로 오탐한다(실측 재현됨).
    LITERAL_TOKEN_RE = re.compile(
        r"Bearer\s+[A-Za-z0-9_\-\.=]{20,}"
        r"|(?<![A-Za-z0-9_-])sk-[A-Za-z0-9]{20,}"
        r"|(?<![A-Za-z0-9_-])ghp_[A-Za-z0-9]{36}"
        r"|(?<![A-Za-z0-9_-])gho_[A-Za-z0-9]{36}"
        r"|(?<![A-Za-z0-9_-])AKIA[0-9A-Z]{16}"
        r"|(?<![A-Za-z0-9_-])xox[baprs]-[A-Za-z0-9-]{10,}"
    )
    # 전부 대문자+언더스코어면 자리표시자로 본다(YOUR_ACCESS_TOKEN_HERE 류) — 실제 키는 대소문자가 섞인다.
    PLACEHOLDER_RE = re.compile(r"^[A-Z][A-Z0-9_]{8,}$")

    STMT_SPLIT = re.compile(r"(?<!\\)(?:&&|\|\||;|[\r\n]+)")
    PIPE_SPLIT = re.compile(r"(?<!\|)\|(?!\|)")
    # A-2: scp/rsync 원격 목적지 판정 — `user@host:` 또는 `점포함호스트:`(단, `://` URL·`\`뒤 Windows 드라이브는 제외).
    REMOTE_TOKEN_RE = re.compile(r"^(?:([A-Za-z0-9_.-]+)@)?([A-Za-z0-9][A-Za-z0-9_.-]*):(?!//)")
    # A-2: scp -i/-F, rsync -e(원격 셸 커맨드, 보통 `ssh -i ~/.ssh/id_rsa` 형태) 값 — 정상 인증 수단이라
    # SENSITIVE_RE 오탐(id_rsa 등) 대상에서 제외한다.
    # 값이 "전송 대상"이 아닌 플래그 — 인증(-i/-F/-e)과 제외/목록 지정(--exclude 등).
    # --exclude .env 는 시크릿을 명시적으로 *빼는* 것이라 유출이 아니다(오탐 실측 재현됨).
    REMOTE_COPY_SKIP_VALUE_FLAGS = {"-i", "-F", "-e",
                                    "--exclude", "--exclude-from", "--include", "--include-from",
                                    "--filter", "--files-from"}
    # .env.example 같은 템플릿은 시크릿이 아니다 — push 게이트(아래 ALLOW)와 같은 기준을 쓴다.
    TEMPLATE_ALLOW_RE = re.compile(r"\.(example|sample|template|dist)$|\.env\.example")
    # A-2: ssh 표준입력 리다이렉트(`< file`) 판정 — `<<`(heredoc)·`<<<`(herestring)는 파일이 아니라 인라인
    # 콘텐츠라 제외(전후에 `<`가 더 있으면 미매치).
    SSH_STDIN_RE = re.compile(r"(?<!<)<(?!<)\s*(\S+)")

    def is_localhost(text):
        return bool(re.search(r"https?://(localhost|127\.0\.0\.1|0\.0\.0\.0)(?::\d+)?(?:[/\s]|$)", text))

    def has_data_exfil_flag(args):
        for a in args:
            a = a.strip("'\"")
            if a in SHORT_DATA_FLAGS:
                return True
            if a.startswith("--"):
                base = a.split("=", 1)[0]
                if base in LONG_DATA_FLAGS:
                    return True
            elif len(a) > 2 and a[:2] in SHORT_DATA_FLAGS:
                # -d@.env, -Ffile=..., -T./file 처럼 값이 붙은 형태
                return True
        return False

    def wrapper_strip(toks):
        # command/nice/nohup/time/xargs/sudo/timeout N/stdbuf <opts>/env <NAME=VAL...|opts> 스트립.
        # bare `env`(뒤에 실제 커맨드가 없는 경우)는 env 자체를 prog로 반환(환경변수 전체 덤프로 취급).
        i = 0
        while i < len(toks):
            t = toks[i]
            # bare 변수할당 프리픽스(NAME=val cmd) — pre-destructive-guard와 대칭 봉합.
            if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t):
                i += 1
                continue
            if t in ("command", "nice", "nohup", "time", "xargs", "sudo"):
                i += 1
                continue
            if t == "timeout" and i + 1 < len(toks):
                i += 2
                continue
            if t == "stdbuf":
                i += 1
                while i < len(toks) and toks[i].startswith("-"):
                    i += 1
                continue
            if t == "env":
                j = i + 1
                while j < len(toks):
                    nxt = toks[j]
                    if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", nxt):
                        j += 1
                        continue
                    if nxt in ENV_OPTS_WITH_ARG:
                        j += 2
                        continue
                    if nxt.startswith("-"):
                        j += 1
                        continue
                    break
                if j < len(toks):
                    i = j
                    continue
                return "env", [], toks[i:i + 1]
            break
        rest = toks[i:]
        if not rest:
            return None, [], []
        # 선행 백슬래시(\git 등 alias 우회)도 제거 — pre-destructive-guard와 대칭 봉합.
        prog = os.path.basename(rest[0].strip("'\"").lstrip("\\"))
        return prog, rest[1:], rest

    def check_data_exfil(seg_text, prog, args):
        if not has_data_exfil_flag(args):
            return
        if is_localhost(seg_text):
            return
        if SENSITIVE_RE.search(seg_text):
            warn(
                f"{prog} 요청에 데이터 전송 플래그와 민감정보 의심 참조가 함께 있습니다: "
                f"{seg_text.strip()[:200]}"
            )

    def check_literal_secret(seg_text, prog):
        # A-3: 데이터 전송 플래그 유무와 무관하게(단순 GET에 헤더로 얹는 경우도 포함) 리터럴 토큰을 본다 —
        # `curl -H "Authorization: Bearer sk-..."`는 -d/-F 같은 데이터 플래그가 없어 check_data_exfil을 안 탄다.
        if is_localhost(seg_text):
            return
        m = None
        for cand in LITERAL_TOKEN_RE.finditer(seg_text):
            tok = cand.group(0)
            # Bearer 뒤가 전부 대문자+언더스코어면 자리표시자(YOUR_ACCESS_TOKEN_HERE) — 실제 키는 대소문자가 섞인다.
            val = tok.split(None, 1)[1] if tok.lower().startswith("bearer") else tok
            if PLACEHOLDER_RE.match(val):
                continue
            m = cand
            break
        if m:
            warn(
                f"{prog} 요청에 리터럴 시크릿/토큰으로 보이는 문자열이 포함되어 있습니다"
                f"(형태만 표시, 값은 남기지 않습니다): {_token_shape(m.group(0))}"
            )

    def _is_remote_token(raw):
        # scp/rsync 인자가 `user@host:path`/`host.domain:path` 형태면 원격 목적지로 판정.
        # user@ 접두 없고 host에 점도 없으면(예: Windows 드라이브 `C:\`, bare 상대경로) 원격 신호로 보지 않는다.
        m = REMOTE_TOKEN_RE.match(raw)
        if not m:
            return False
        user, host = m.group(1), m.group(2)
        if host in ("localhost", "127.0.0.1", "0.0.0.0"):
            return False
        return bool(user) or "." in host

    def check_remote_copy_exfil(seg_text, prog, args):
        # A-2: scp/rsync는 curl처럼 -d/--data 같은 '데이터 전송 플래그'가 없다 — 파일 인자 자체가 전송
        # 페이로드다. 그래서 curl류와 다른 로직: 인자 중 원격 목적지(user@host:)가 있고, 동시에 로컬(비-원격)
        # 인자가 SENSITIVE_RE에 걸리면 경고. -i/-F(scp 인증서·설정파일)·-e(rsync 원격 셸, 보통
        # `ssh -i ~/.ssh/id_rsa`)의 값은 정상 인증 수단이라 스캔에서 제외(오탐 방지).
        if prog not in ("scp", "rsync"):
            return
        remote_present = False
        local_sensitive = None
        skip_next = False
        for a in args:
            raw = a.strip("'\"")
            if skip_next:
                skip_next = False
                continue
            if raw in REMOTE_COPY_SKIP_VALUE_FLAGS:
                skip_next = True
                continue
            if raw.startswith("--") and "=" in raw and raw.split("=", 1)[0] in REMOTE_COPY_SKIP_VALUE_FLAGS:
                continue  # --exclude=.env 등호형
            if not raw or raw.startswith("-"):
                continue
            if _is_remote_token(raw):
                remote_present = True
                continue
            if SENSITIVE_RE.search(raw) and not TEMPLATE_ALLOW_RE.search(raw):
                local_sensitive = raw
        if remote_present and local_sensitive:
            warn(
                f"{prog} 명령이 민감정보 의심 파일을 원격 목적지로 전송하는 것으로 보입니다: "
                f"{seg_text.strip()[:200]}"
            )

    def _token_shape(tok):
        # 값을 남기지 않는다 — push 게이트가 "존재만 알리고 값은 출력 안 함"을 원칙으로 하는 것과 동일.
        for pre, name in (("sk-", "OpenAI 키"), ("ghp_", "GitHub PAT"), ("gho_", "GitHub OAuth"),
                          ("AKIA", "AWS 액세스 키"), ("xox", "Slack 토큰")):
            if tok.startswith(pre):
                return f"{name} 형태({pre}…)"
        return "Bearer 토큰 형태"

    def check_ssh_stdin_exfil(seg_text, prog):
        # A-2: ssh는 scp/rsync와 달리 파일 인자로 전송하지 않는다 — 흔한 유출 경로는 민감파일을 표준입력으로
        # 흘려보내는 것(`ssh host < .env`). `-i ~/.ssh/id_rsa`(식별키 플래그)는 리다이렉트가 아니므로 안 걸린다.
        if prog != "ssh":
            return
        for m in SSH_STDIN_RE.finditer(seg_text):
            target = m.group(1).strip("'\"")
            if SENSITIVE_RE.search(target):
                warn(
                    f"ssh 명령이 민감정보 의심 파일을 표준입력으로 전달하는 것으로 보입니다: "
                    f"{seg_text.strip()[:200]}"
                )
                return

    def analyze(text, depth=0):
        if depth > 3 or not text:
            return
        for stmt in STMT_SPLIT.split(text):
            stmt = stmt.strip()
            if not stmt:
                continue
            stage_texts = [s.strip() for s in PIPE_SPLIT.split(stmt) if s.strip()]
            stages = []
            for st in stage_texts:
                toks = st.split()
                try:
                    qtoks = shlex.split(st, posix=True)
                except ValueError:
                    qtoks = None
                prog, args, _rest = wrapper_strip(toks)
                stages.append((st, prog, args, qtoks))

            for st, prog, args, qtoks in stages:
                # bash/sh -c '<inner>' 재귀 검사(래퍼가 env 뒤 등 어디에 있든).
                if qtoks:
                    for i2, t2 in enumerate(qtoks):
                        base = os.path.basename(t2.strip("'\""))
                        if base in SHELLS and i2 + 2 < len(qtoks) and qtoks[i2 + 1] in ("-c", "--command"):
                            analyze(qtoks[i2 + 2], depth + 1)
                            break
                        if base in SHELLS and i2 + 1 < len(qtoks) and qtoks[i2 + 1].startswith("--command="):
                            analyze(qtoks[i2 + 1].split("=", 1)[1], depth + 1)
                            break
                if prog in ("curl", "wget"):
                    check_data_exfil(st, prog, args)
                    check_literal_secret(st, prog)
                # A-2: scp/rsync/ssh는 인자 형태가 curl류와 달라(원격 목적지 `user@host:path`) 별도 로직 —
                # qtoks(따옴표 보존 토큰)가 있으면 그걸로 재분리해서 `-e "ssh -i ~/.ssh/id_rsa"`처럼 따옴표로
                # 묶인 원격 셸 문자열이 naive 공백분리로 쪼개져 오탐(id_rsa 등)나는 것을 막는다.
                if qtoks:
                    qprog, qargs, _ = wrapper_strip(qtoks)
                else:
                    qprog, qargs = prog, args
                check_remote_copy_exfil(st, qprog, qargs)
                check_ssh_stdin_exfil(st, qprog)

            for i2 in range(len(stages) - 1):
                _, progA, argsA, _ = stages[i2]
                _, progB, _argsB, _ = stages[i2 + 1]
                if progA in ("curl", "wget") and progB in INTERPRETERS:
                    warn(
                        f"원격 코드 실행 패턴: {progA} 결과를 {progB}로 파이프 — "
                        "신뢰 안 된 원격 스크립트를 검토 없이 실행합니다."
                    )
                if progA in ("env", "printenv") and progB in NET_TOOLS_FOR_ENV:
                    warn(
                        f"환경변수 전체({progA})를 {progB}로 파이프 — 시크릿이 통째로 유출될 수 있습니다."
                    )
                # A-2: 민감파일을 읽어(cat/type) ssh/nc류로 파이프 — `cat ~/.ssh/id_rsa | ssh host '...'` 같은
                # 원격 유출 경로. 단순 `-i ~/.ssh/id_rsa` 플래그 사용(정상 인증)은 파이프가 아니므로 안 걸린다.
                if progA in READ_TOOLS and progB in ("ssh", "nc", "ncat", "netcat") and any(
                    SENSITIVE_RE.search(a.strip("'\"")) for a in argsA
                ):
                    warn(
                        f"민감정보 의심 파일을 {progA}로 읽어 {progB}로 파이프 — 원격 유출 가능성이 있습니다."
                    )

    # 경고 분석은 자체 격리 — analyze가 예외를 던져도 아래 push 하드게이트(exit 2)는 반드시 평가돼야 한다.
    # 바깥 except가 이걸 삼키면 게이트가 조용히 스킵되고 exit 0이 된다(가장 비싼 실패 모드).
    try:
        analyze(cmd)
    except Exception:
        print("exfil-guard: 경고 분석 중 오류 — 유출 경고는 건너뜁니다(하드게이트는 계속 평가).", file=sys.stderr)

    for w in warnings:
        print(f"exfil-guard 경고: {w}", file=sys.stderr)

    # === git push 시크릿 하드게이트 (nextgen 2순위) ===
    # secret-scan(PostToolUse)은 경고만·Edit/Write만 봐서 (a) 디스크에 이미 있던 .env가 git add되면 안 봄
    # (b) push로 나가는 걸 못 막음. 커밋된 .env가 push 이력에 잔존하는 사고가 실제로 일어난다. push=exfiltration이라
    # 여기(egress guard)에 흡수: git push가 .env/시크릿을 담고 있으면 warn이 아니라 **차단(exit 2)**.
    # nudge 실패의 정확한 처방 = 하드게이트. (bypassPermissions 상시라 유일 방어선.)
    import re as _re2
    import subprocess as _sp
    push_seg = None
    for _seg in STMT_SPLIT.split(cmd):
        _t = _seg.split()
        if _t and os.path.basename(_t[0].strip("'\"")) == "git" and "push" in _t:
            push_seg = _seg
            break
    if push_seg is not None:
        # repo dir: 명령 내 `cd <path>` 우선, 없으면 훅 cwd, 없으면 현재.
        repo = d.get("cwd") or os.getcwd()
        _m = _re2.search(r"(?:^|[;&|]|\bcd)\s+(/[^\s;&|]+|~[^\s;&|]*|\.[^\s;&|]*)", cmd)
        if _m:
            cand = os.path.expanduser(_m.group(1))
            if os.path.isdir(cand):
                repo = cand

        def _git(args, timeout=6):
            try:
                r = _sp.run(["git", "-C", repo, *args], capture_output=True, text=True, timeout=timeout)
                return r.stdout if r.returncode == 0 else ""
            except Exception:
                return ""

        ENVRE = _re2.compile(r"(^|/)\.env(\.[A-Za-z0-9_.-]+)?$")
        ALLOW = _re2.compile(r"\.(example|sample|template|dist)$|\.env\.example")
        # tracked + staged 파일에서 .env 계열 탐지(.example류 제외).
        files = set()
        for ln in (_git(["ls-files"]) + "\n" + _git(["diff", "--cached", "--name-only"])).splitlines():
            ln = ln.strip()
            if ln and ENVRE.search(ln) and not ALLOW.search(ln):
                files.add(ln)
        # staged 내용의 고신뢰 시크릿 패턴(값 출력 안 함 — 존재만).
        SECRET = _re2.compile(r"AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{36}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.")
        staged = _git(["diff", "--cached"])
        secret_hit = bool(SECRET.search(staged))
        if files or secret_hit:
            why = []
            if files:
                why.append(".env 계열 " + str(len(files)) + "개 tracked/staged(" + ", ".join(sorted(files)[:3]) + ")")
            if secret_hit:
                why.append("staged diff에 고신뢰 시크릿 패턴")
            print(
                "exfil-guard 차단: git push가 시크릿을 담고 있습니다 — " + " · ".join(why) + ". "
                "push하면 원격 이력에 영구 잔존합니다(커밋된 .env가 push 이력에 남는 사고 전례). "
                "`echo '.env' >> .gitignore && git rm --cached <파일>` 후 재시도하거나, 의도된 것이면 사용자가 직접 push하세요.",
                file=sys.stderr,
            )
            sys.exit(2)

try:
    main()
except SystemExit:
    raise
except Exception:
    pass
sys.exit(0)
PY
exit $?
