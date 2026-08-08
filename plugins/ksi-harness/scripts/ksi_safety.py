#!/usr/bin/env python3
"""ksi_safety.py — hard guard 2종(파괴적 명령 · git push 시크릿 유출) 단일 모듈.

pre-destructive-guard.sh · exfil-guard.sh가 각각 얇은 launcher로
`python3 ksi_safety.py destructive|egress`를 부른다. 목적은 shell heredoc 안에 Python을 박던
기존 구조(인용 취약성의 근원 — 셸 인용이 깨지면 훅이 조용히 죽던 사고 클래스)를 없애는 것이고,
로직 자체는 이관 전과 동일하게 보존한다(회귀 22케이스로 equivalence 확인, harness-selfcheck.py smoke).

범용 훅 프레임워크가 아니다 — 이 두 hard guard 전용. 나머지 12개 훅(soft nudge)은 이관 대상이 아니다:
실패해도 통과(exit 0)라 shell+embedded-python이 갖는 위험이 이 둘과 다르고, 이관의 실익이 낮다.
"""
import json
import os
import posixpath
import re
import shlex
import sys


def run_destructive(payload):
    try:
        d = json.loads(payload or "{}")
    except Exception:
        return 0
    if d.get("tool_name") != "Bash":
        return 0
    cmd = (d.get("tool_input") or {}).get("command", "") or ""
    if not cmd:
        sys.exit(0)

    def block(reason):
        print(f"pre-destructive-guard 차단: {reason}", file=sys.stderr)
        sys.exit(2)


    def soft_block(reason):
        # 로컬 미커밋/미추적 손실 계열(reset --hard·clean -f). 예전엔 KSI_HOOKS 스위치로 경고까지 낮출 수 있었으나
        # 스위치를 없애며 차단으로 통일했다 — 미커밋 작업은 git 에도 rewind 에도 없어서 사실상 되돌리기-불가다.
        block(reason)

    HOME = os.path.expanduser("~")
    SEG_SPLIT = re.compile(r"(?<!\\)(?:[;&|]+|[\r\n]+)")
    SHELLS = ("bash", "sh", "zsh", "dash")
    ENV_OPTS_WITH_ARG = ("-C", "-S", "-u", "--chdir", "--unset")

    def check_segments(text, depth=0):
        if depth > 3 or not text:
            return
        for seg in SEG_SPLIT.split(text):
            seg = seg.strip()
            if not seg:
                continue
            check_one(seg, depth)

    def check_one(seg, depth):
        # 따옴표 보존 파싱 우선 시도(-c 뒤 인용 문자열 복원용). 실패하면 whitespace split로 폴백(기존 heuristic).
        try:
            qtoks = shlex.split(seg, posix=True)
        except ValueError:
            qtoks = None

        # bash/sh/zsh/dash -c '<inner>' — 래퍼 자체가 어디 있든(env 뒤 등) inner를 재귀 검사.
        if qtoks:
            for i, t in enumerate(qtoks):
                if os.path.basename(t.strip("'\"")) in SHELLS and i + 2 < len(qtoks) and qtoks[i + 1] in ("-c", "--command"):
                    check_segments(qtoks[i + 2], depth + 1)
                    break
                if os.path.basename(t.strip("'\"")) in SHELLS and i + 1 < len(qtoks) and qtoks[i + 1].startswith("--command="):
                    check_segments(qtoks[i + 1].split("=", 1)[1], depth + 1)
                    break

        toks = seg.split()
        # 래퍼 스트립: command/nice/nohup/time/xargs/timeout N/stdbuf <opts>/sudo/env <NAME=VAL...|opts>
        i = 0
        while i < len(toks):
            t = toks[i]
            # bare 변수할당 프리픽스(NAME=val cmd) — 셸 표준 구문. env 래퍼는 처리하면서 이걸
            # 누락하면 `FOO=bar rm -rf ~`로 하드가드가 우회된다(자가감사 CONFIRMED, 실측 exit0).
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
                i += 1
                while i < len(toks):
                    nxt = toks[i]
                    if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", nxt):
                        i += 1
                        continue
                    if nxt in ENV_OPTS_WITH_ARG:
                        i += 2
                        continue
                    if nxt.startswith("-"):
                        i += 1
                        continue
                    break
                continue
            break
        toks = toks[i:]
        if not toks:
            return
        # 선행 백슬래시(\rm 등 alias 우회 관용구)도 제거 — 안 벗기면 `\rm -rf ~`·`\git push -f`가
        # prog-name 하드블록 전체를 우회한다(자가감사 CONFIRMED, 실측 exit0).
        prog = os.path.basename(toks[0].strip("'\"").lstrip("\\"))
        args = toks[1:]

        # === control-plane 자기수정 가드 ===
        # 「신뢰 경계」의 기계 강제. 텍스트 규칙만 있고 강제가 0이라 `echo {} > ~/.claude/settings.json`·
        # `sed -i`·`rm hooks/*.sh`가 전부 통과하던 구멍(2026-08-08 실측 exit0).
        # 보호 대상은 '제어면'만 — 가드 훅과 셸/설정 rc. auto-memory(projects/**)와 scripts·workflows
        # (설치 경로)는 제외한다. 넓히면 /ksi-setup 설치와 메모리 쓰기를 막는다.
        CP_FILES = {
            HOME + "/.claude/settings.json", HOME + "/.claude/settings.local.json",
            HOME + "/.bashrc", HOME + "/.bash_profile", HOME + "/.profile", HOME + "/.zshrc",
        }
        CP_DIRS = (HOME + "/.claude/hooks",)

        def _cp_expand(p):
            p = p.strip("'\"").replace("${HOME}", HOME).replace("$HOME", HOME)
            if p.startswith("~"):
                p = HOME + p[1:]
            return posixpath.normpath(p) if p else p

        def _is_control_plane(p):
            n = _cp_expand(p)
            if not n or n.startswith(HOME + "/.claude/projects/"):
                return False
            return n in CP_FILES or any(n == dd or n.startswith(dd + "/") for dd in CP_DIRS)

        # (a) 리다이렉트 대상(`> path`·`>> path`) — 2>&1 같은 fd 복제는 &가 제외문자라 안 걸린다.
        cp_targets = [m.group(1) for m in re.finditer(r">>?\s*([^\s;|&<>]+)", seg)]
        # (b) 인플레이스·파괴 계열의 위치인자.
        if prog in ("sed", "perl") and any(a == "-i" or (a.startswith("-i") and not a.startswith("--")) for a in args):
            cp_targets += [a for a in args if not a.startswith("-")]
        elif prog == "dd":
            cp_targets += [a.split("=", 1)[1] for a in args if a.startswith("of=")]
        elif prog in ("truncate", "shred", "tee", "rm"):
            cp_targets += [a for a in args if not a.startswith("-")]
        elif prog == "mv":
            # mv는 소스도 본다 — 제어면 밖으로 옮기는 건 그 자리에서 삭제하는 것과 같다.
            cp_targets += [a for a in args if not a.startswith("-")]
        elif prog in ("cp", "ln", "install"):
            # 목적지만 본다 — 마지막 위치인자. 소스까지 세면 `cp ~/.claude/settings.json ./backup.json`
            # 같은 '제어면을 읽어 밖으로 복사'가 차단돼 백업조차 못 한다(실측 오차단). 읽기는 위험이 아니다.
            # 단 -t/--target-directory 형태는 목적지가 앞에 오므로 보수적으로 전량 검사한다.
            _pos = [a for a in args if not a.startswith("-")]
            if any(a == "-t" or a.startswith("--target-directory") for a in args):
                cp_targets += _pos
            elif _pos:
                cp_targets.append(_pos[-1])
        for _t in cp_targets:
            if _is_control_plane(_t):
                block(f"제어면 수정: {_t} — 사용자가 직접 요청했을 때만 고친다(「신뢰 경계」). 셸 우회 대신 편집 도구로, 요청받고 하세요.")

        if prog == "rm":
            short = "".join(a.lstrip("-") for a in args if a.startswith("-") and not a.startswith("--"))
            longf = [a for a in args if a.startswith("--")]
            recursive = ("r" in short.lower()) or ("--recursive" in longf)
            # force 요구 제거 — force 없는 `rm -r ~`도 홈을 지운다. 표적은 아래처럼 여전히
            # 복구불가급(루트/홈/시스템최상위/보호디렉토리)만이라 정당한 rm -r <scratch/node_modules류>는 통과.
            if recursive:
                for t in (a for a in args if not a.startswith("-")):
                    t2 = t.strip("'\"")
                    exp = t2.replace("${HOME}", HOME).replace("$HOME", HOME)
                    if exp.startswith("~"):
                        exp = HOME + exp[1:]
                    # POSIX 셸 명령의 경로라 posixpath로 정규화 — os.path.normpath는 Windows에서 '/'를 '\'로 바꿔
                    # `norm == "/"`·`norm.count("/")` 검사가 전부 빗나가 `rm -rf /`가 통과하던 구멍.
                    norm = posixpath.normpath(exp) if exp else exp
                    # 루트: '/' 뿐 아니라 '//'·'///'(posixpath.normpath('//')=='//', POSIX 특례로 보존)도 전부 루트로 취급.
                    is_root = norm.startswith("/") and norm.strip("/") == ""
                    if is_root or t2 in ("/*", "*", ".", "..") or norm.rstrip("/") == HOME:
                        block(f"rm -r 복구불가급 대상: {t}")
                    if norm.startswith("/") and norm.count("/") == 1 and norm not in ("/tmp",):
                        block(f"rm -r 시스템 최상위 디렉토리: {t}")
                    if norm in (HOME + "/Desktop", HOME + "/.claude"):
                        block(f"rm -r 보호 디렉토리: {t} (필요 시 사용자가 직접)")

        # push는 -C/--git-dir 등 전역 옵션 뒤에도 올 수 있어 위치 무관 탐색.
        # --force-with-lease와 --force 병용 시 git은 --force가 이기므로 병용도 차단(단독 lease만 통과).
        if prog == "git" and "push" in args:
            pargs = args[args.index("push"):]
            # short-flag 스택(-fu·-uf·-fq 등)도 f 포함이면 force — git은 -fu를 -f -u로 파싱한다. exact 토큰 매칭만으론
            # -fu가 새던 갭 봉합: rm/clean과 동일하게 단일-대시 플래그를 문자단위로 전개.
            pshort = "".join(a.lstrip("-") for a in pargs if a.startswith("-") and not a.startswith("--"))
            if ("f" in pshort) or any(a == "--force" for a in pargs):
                block("git push --force(-f·-fu 등 f 포함) — --force-with-lease를 단독으로 쓰거나 사용자가 직접 실행(사용자 승인 사항)")

        if prog == "git" and "reset" in args:
            rargs = args[args.index("reset"):]
            if "--hard" in rargs:
                soft_block("git reset --hard — 미커밋 변경이 사라진다. git 에도 rewind 에도 없어 되살릴 수 없다. 정말 버릴 거면 사용자가 직접 실행")

        if prog == "git" and "clean" in args:
            cargs = args[args.index("clean"):]
            cshort = "".join(a.lstrip("-") for a in cargs if a.startswith("-") and not a.startswith("--"))
            if ("f" in cshort) or ("--force" in cargs):
                soft_block("git clean -f — 미추적 파일이 사라진다. 되살릴 수 없다. 정말 버릴 거면 사용자가 직접 실행")

        if prog in ("psql", "mysql", "mariadb") or (prog == "supabase" and "db" in args):
            DROP_RE = re.compile(r"(?i)\bdrop\s+(database|schema)\b")
            if DROP_RE.search(seg):
                block("인터랙티브 DROP DATABASE/SCHEMA — 마이그레이션 경로로만(사용자 승인 사항)")
            # 명령줄 문자열만 보면 `psql -f drop.sql`·`psql < drop.sql`·heredoc의 DROP은 안 보인다 —
            # 실행될 SQL 파일 내용에도 같은 정규식을 적용한다. 읽지 못하는 파일은 차단 대신 사각을 가시화(은폐 금지).
            # heredoc은 cmd 전역이 아니라 *실제 heredoc body*만 검사한다 — 전역 매칭은 무관 세그먼트
            # (echo "DROP DATABASE는 위험" 같은 문서 작업)가 psql heredoc과 한 호출에 있을 때 정상 작업을 과차단한다.
            if "<<" in seg:
                for hm in re.finditer(r"<<-?\s*(['\"]?)([A-Za-z_]\w*)\1", cmd):
                    delim = re.escape(hm.group(2))
                    body_m = re.search(r"<<-?\s*['\"]?" + delim + r"['\"]?[^\n]*\n(.*?)\n[ \t]*" + delim + r"\b", cmd, re.S)
                    if body_m and DROP_RE.search(body_m.group(1)):
                        block("psql/mysql heredoc 경유 DROP DATABASE/SCHEMA — 마이그레이션 경로로만(사용자 승인 사항)")
            sql_files = []
            for j, a in enumerate(args):
                a2 = a.strip("'\"")
                if prog == "psql" and a2 in ("-f", "--file") and j + 1 < len(args):
                    sql_files.append(args[j + 1])
                elif prog == "psql" and a2.startswith("-f") and len(a2) > 2 and not a2.startswith("--"):
                    sql_files.append(a2[2:])
                elif a2.startswith("--file="):
                    sql_files.append(a2.split("=", 1)[1])
            # `<` 리다이렉트 파일은 quote-aware 토큰(qtoks)에서 뽑는다 — raw 정규식은 인용부호를 몰라
            # `psql -c "SELECT ... WHERE a < 5"`의 SQL 비교연산자를 파일로 오인해 반복 노이즈를 낸다.
            if qtoks:
                for j, t in enumerate(qtoks):
                    if t == "<" and j + 1 < len(qtoks):
                        sql_files.append(qtoks[j + 1])
            else:
                m = re.search(r"(?<!<)<(?!<)\s*([^\s;|&<>]+)", seg)
                if m:
                    sql_files.append(m.group(1))
            for f in sql_files:
                exp = f.strip("'\"").replace("${HOME}", HOME).replace("$HOME", HOME)
                if exp.startswith("~"):
                    exp = HOME + exp[1:]
                try:
                    if os.path.isfile(exp) and os.path.getsize(exp) <= 5 * 1024 * 1024:
                        with open(exp, errors="ignore") as fh:
                            if DROP_RE.search(fh.read()):
                                block(f"SQL 파일 경유 DROP DATABASE/SCHEMA: {f} — 마이그레이션 경로로만(사용자 승인 사항)")
                    else:
                        print(f"pre-destructive-guard: SQL 입력 {f} 은(는) 검사하지 못함(부재/과대) — DROP 여부 직접 확인", file=sys.stderr)
                except Exception:
                    print(f"pre-destructive-guard: SQL 입력 {f} 읽기 실패 — 가드 미검사", file=sys.stderr)

    check_segments(cmd)
    return 0


def run_egress(payload):
    try:
        d = json.loads(payload or "{}")
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

        class _GitFail(Exception):
            pass

        def _git(args, timeout=6, required=True):
            try:
                r = _sp.run(["git", "-C", repo, *args], capture_output=True, text=True, timeout=timeout)
            except Exception as _e:
                if required:
                    raise _GitFail("git " + args[0] + " 실행 실패(" + type(_e).__name__ + ")")
                return ""
            if r.returncode != 0:
                if required:
                    raise _GitFail("git " + args[0] + " → rc=" + str(r.returncode))
                return ""
            return r.stdout

        ENVRE = _re2.compile(r"(^|/)\.env(\.[A-Za-z0-9_.-]+)?$")
        ALLOW = _re2.compile(r"\.(example|sample|template|dist)$|\.env\.example")
        # 값은 남기지 않는다 — 존재만 알린다.
        SECRET = _re2.compile(r"AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{36}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.")
        CAP = 1000
        files = set()
        secret_hit = False
        n_out = 0
        try:
            # 검사 대상은 staging도 working tree도 아니라 **이번 push로 새로 전송되는 커밋 범위**다.
            #  - staging(diff --cached)을 보면 안 되는 이유: add→commit→push 정상 흐름에선 push 시점에
            #    staging이 항상 비어 있어 게이트가 통째로 무력해진다(2026-08-08 실증 — 커밋된 AKIA가 통과).
            #  - 범위의 최종 diff를 보면 안 되는 이유: commitA에서 키를 넣고 commitB에서 지우면 최종 diff는
            #    깨끗해도 commitA 객체 자체가 원격으로 전송돼 이력에 영구 잔존한다.
            # 그래서 범위 전체의 **커밋별 패치**(log -p)를 본다.
            # git repo 자체가 아니면 검사 불가 → 아래 fail-closed로 떨어뜨린다.
            # (required=False로 두면 "repo 아님"과 "커밋 없음"이 둘 다 빈 문자열이 돼 구분이 사라진다.)
            _git(["rev-parse", "--git-dir"])
            if not _git(["rev-parse", "--verify", "HEAD"], required=False).strip():
                raise StopIteration  # repo는 맞는데 커밋이 아직 없다 — 전송될 것도 없다
            up = _git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], required=False).strip()
            rng = [up + "..HEAD"] if up else ["HEAD", "--not", "--remotes"]
            try:
                n_out = int((_git(["rev-list", "--count", *rng]) or "0").strip())
            except ValueError:
                n_out = 0
            patch = _git(["log", "-p", "--no-merges", "--no-color", "-n", str(CAP), *rng], timeout=20)
            names = _git(["log", "--name-only", "--pretty=format:", "-n", str(CAP), *rng], timeout=20)
            # .env 계열 — 전송 커밋에 등장한 경로 + 현재 tracked(트리에 있으면 push로 함께 나간다).
            for ln in (_git(["ls-files"]) + "\n" + names).splitlines():
                ln = ln.strip()
                if ln and ENVRE.search(ln) and not ALLOW.search(ln):
                    files.add(ln)
            secret_hit = bool(SECRET.search(patch))
        except StopIteration:
            pass
        except BaseException as _e:
            # hard gate는 fail-open하지 않는다. git push라고 식별한 뒤 검사가 불가능해지면
            # "검사할 수 없음"을 "안전함"으로 바꿔 읽지 않는다(경고 분석과 달리 여기는 차단이 기본값).
            if isinstance(_e, SystemExit):
                raise
            print(
                "exfil-guard 차단: git push의 시크릿 검사를 수행할 수 없습니다 — "
                + (str(_e) or type(_e).__name__) + ". "
                "검사 불가를 통과로 처리하지 않습니다. 원인을 해결한 뒤 재시도하거나, 사용자가 직접 push하세요.",
                file=sys.stderr,
            )
            sys.exit(2)

        if n_out > CAP:
            print(
                "exfil-guard: 전송 커밋 " + str(n_out) + "개 중 최근 " + str(CAP) + "개만 검사했습니다(부분 검사).",
                file=sys.stderr,
            )
        if files or secret_hit:
            why = []
            if files:
                why.append(".env 계열 " + str(len(files)) + "개(" + ", ".join(sorted(files)[:3]) + ")")
            if secret_hit:
                why.append("전송 커밋 패치에 고신뢰 시크릿 패턴")
            print(
                "exfil-guard 차단: git push가 시크릿을 담고 있습니다 — " + " · ".join(why) + ". "
                "push하면 원격 이력에 영구 잔존합니다(커밋된 .env가 push 이력에 남는 사고 전례). "
                "이미 커밋된 것이라면 이력에서 제거해야 합니다(git rm --cached + .gitignore만으로는 과거 커밋이 남습니다). "
                "의도된 것이면 사용자가 직접 push하세요.",
                file=sys.stderr,
            )
            sys.exit(2)

if __name__ == "__main__":
    _mode = sys.argv[1] if len(sys.argv) > 1 else ""
    _payload = sys.stdin.read()
    if _mode == "destructive":
        # 원본(pre-destructive-guard.sh)에 전역 catch-all이 없었다 — 예상 못 한 예외는 트레이스백과 함께
        # 비정상 종료(exit 1)로 드러나야 한다(조용히 통과·조용히 차단 둘 다 아님). 그 동작을 그대로 보존한다.
        run_destructive(_payload)
        sys.exit(0)
    elif _mode == "egress":
        # 원본(exfil-guard.sh) 그대로: SystemExit(하드게이트 exit 2)만 전파하고 나머지 예외는 삼켜 exit 0.
        try:
            run_egress(_payload)
        except SystemExit:
            raise
        except Exception:
            pass
        sys.exit(0)
    else:
        sys.exit(0)
