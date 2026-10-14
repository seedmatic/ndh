#!/usr/bin/env python3
"""Managed PreToolUse hook: refuse mutating commands however they are wrapped.

The deny list in managed settings matches the command TEXT Claude writes, so a global option
before the verb (`kubectl -n x delete`), a launcher (`bash -c`, `nix run`, `ssh host …`) or a
spelling variant (`rm -fr`) slips past it. This hook normalises the command first, then compares
it to the same verb table.

Protocol (code.claude.com/docs/en/hooks): JSON on stdin; exit 2 blocks the call with stderr as
the reason, whatever the permission mode. A PreToolUse hook that crashes, times out or exits with
any other code FAILS OPEN, so every internal error here exits 2: an unreadable command is refused,
never waved through.
"""

import json
import os
import re
import shlex
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MAX_DEPTH = 8

SEPARATORS = {"&&", "||", "|", "|&", ";", "&", ";;", "(", ")"}
KEYWORDS = {"if", "then", "else", "elif", "fi", "do", "done", "while", "until", "for", "case",
            "esac", "!", "{", "}", "function", "select", "in"}
REDIRECTS = re.compile(r"^\d*(?:<<<|<<-|<<|>>|>&|<&|&>>|&>|>\||<>|<|>)$")
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "fish"}
CLAUDE_DIR = re.compile(r"^(?:~|\$\{?HOME\}?|/(?:Users|home)/[^/]+|/var/root)/\.claude(?:$|[./_-])")


class Refused(Exception):
    """A structural reason to refuse without looking further (too deep, unparseable)."""


def load_table():
    with open(os.path.join(HERE, "verbs.json"), encoding="utf-8") as fh:
        return json.load(fh)


HEREDOC = re.compile(r"<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
# Commands that run their standard input, or wrap a command that may: a heredoc fed to one of
# these is code. Everything else (`cat`, `tee`, `git commit -F -`, `jq`) receives it as data.
RUNS_STDIN = SHELLS | {"ssh", "sudo", "doas", "env", "flox", "nix", "eval", "exec", "xargs", "timeout",
                       "nice", "nohup", "command", "time", "watch", "source", "."}


def heredoc_is_code(text, op, after, eol):
    """Whether the heredoc whose operator starts at OP (delimiter ending at AFTER) feeds a runner."""
    head = re.split(r"&&|\|\||[;|&(]", text[text.rfind("\n", 0, op) + 1:op])[-1].split()
    words = [w for w in head if not ASSIGNMENT.match(w)]
    if words and os.path.basename(words[0]) in RUNS_STDIN:
        return True
    rest = re.split(r"&&|\|\||;", text[after:eol])[0]
    return any(os.path.basename(w) in RUNS_STDIN for w in re.findall(r"\|&?\s*(\S+)", rest))


def match_paren(text, i):
    """Index just past the `)` closing the `(` at I, skipping quoted text and nested forms."""
    depth, j, n, resume = 1, i + 1, len(text), {}
    while j < n and depth:
        c = text[j]
        if c == "\\":
            j += 2
            continue
        if c == "\n" and j in resume:
            j = resume.pop(j)
            continue
        if text.startswith("<<", j) and not text.startswith("<<<", j):
            eol = text.find("\n", j)
            if eol >= 0 and eol not in resume:
                pos = eol + 1
                for m in HEREDOC.finditer(text, j, eol):
                    end = re.compile(r"^" + ("\t*" if m.group(1) else "") + re.escape(m.group(3)) + r"$", re.M).search(text, pos)
                    if not end:
                        raise Refused("unterminated heredoc")
                    pos = end.end() + 1
                resume[eol] = min(pos, n)
        if c == "'" or text.startswith("$'", j):
            j = text.find("'", j + (2 if c == "$" else 1))
            while j > 0 and c == "$" and text[j - 1] == "\\":
                j = text.find("'", j + 1)
            if j < 0:
                raise Refused("unbalanced quote")
        elif c == '"':
            k = j + 1
            while k < n and text[k] != '"':
                if text[k] == "\\":
                    k += 1
                elif text.startswith("$(", k):
                    k = match_paren(text, k + 1) - 1
                k += 1
            if k >= n:
                raise Refused("unbalanced quote")
            j = k
        elif c == "`":
            j = text.find("`", j + 1)
            if j < 0:
                raise Refused("unbalanced backtick")
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        j += 1
    if depth:
        raise Refused("unbalanced substitution")
    return j


def heredoc_substitutions(body):
    """`$(…)` and backtick bodies in an UNQUOTED heredoc, which the shell runs even when the
    heredoc itself is data. Quotes are literal there, so prose apostrophes do not count."""
    found, i, n = [], 0, len(body)
    while i < n:
        if body[i] == "\\":
            i += 2
            continue
        if body.startswith("$(", i) and not body.startswith("$((", i):
            depth, j = 1, i + 2
            while j < n and depth:
                depth += {"(": 1, ")": -1}.get(body[j], 0)
                j += 1
            if depth:
                raise Refused("unbalanced substitution in a heredoc")
            found.append(body[i + 2:j - 1])
            i = j
            continue
        if body[i] == "`":
            j = body.find("`", i + 1)
            if j < 0:
                raise Refused("unbalanced backtick in a heredoc")
            found.append(body[i + 1:j])
            i = j + 1
            continue
        i += 1
    return found


def extract_substitutions(text):
    """Pull `$(…)`, `<(…)`, `>(…)` and backtick bodies out of TEXT.

    Returns (outer, bodies): OUTER has each substitution replaced by a neutral word and every
    unquoted newline turned into `;`, so multi-line scripts are analysed line by line. A heredoc
    body is analysed only when it feeds something that runs it (see `heredoc_is_code`); fed to
    `cat` or `git commit -F -`, it is data, and a commit message that names a verb is not a call.
    """
    out, bodies, resume = [], [], {}
    i, n, quote = 0, len(text), None
    while i < n:
        c = text[i]
        if quote == "'":
            out.append(c)
            if c == "'":
                quote = None
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            out.append(text[i:i + 2])
            i += 2
            continue
        if c in "\"'" and quote is None:
            quote = c
            out.append(c)
            i += 1
            continue
        if c == '"' and quote == '"':
            quote = None
            out.append(c)
            i += 1
            continue
        if c in "$<>" and i + 1 < n and text[i + 1] == "(" and not (c == "$" and text[i + 2:i + 3] == "("):
            j = match_paren(text, i + 1)
            bodies.append(text[i + 2:j - 1])
            out.append(" __subst__ ")
            i = j
            continue
        if c == "`":
            j = text.find("`", i + 1)
            if j < 0:
                raise Refused("unbalanced backtick")
            bodies.append(text[i + 1:j])
            out.append(" __subst__ ")
            i = j + 1
            continue
        if c == "$" and quote is None and text.startswith("$'", i):
            j = i + 2
            while j < n and text[j] != "'":
                j += 2 if text[j] == "\\" else 1
            if j >= n:
                raise Refused("unbalanced quote")
            out.append(shlex.quote(text[i + 2:j].encode("latin-1", "backslashreplace").decode("unicode_escape")))
            i = j + 1
            continue
        if c == "#" and quote is None and (i == 0 or text[i - 1] in " \t\n;|&("):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if c == "<" and quote is None and text.startswith("<<", i) and not text.startswith("<<<", i):
            eol = text.find("\n", i)
            if eol >= 0 and eol not in resume:
                pos = eol + 1
                for m in HEREDOC.finditer(text, i, eol):
                    end_rx = re.compile(r"^" + ("\t*" if m.group(1) else "") + re.escape(m.group(3)) + r"$", re.M)
                    end = end_rx.search(text, pos)
                    if not end:
                        raise Refused("unterminated heredoc")
                    body = text[pos:end.start()]
                    if heredoc_is_code(text, m.start(), m.end(), eol):
                        bodies.append(body)
                    elif not m.group(2):
                        bodies.extend(heredoc_substitutions(body))
                    pos = end.end() + 1
                resume[eol] = min(pos, n)
        if c == "\n" and quote is None:
            out.append(" ; ")
            i = resume.pop(i, i + 1)
            continue
        out.append(c)
        i += 1
    if quote:
        raise Refused("unbalanced quote")
    return "".join(out), bodies


def simple_commands(text):
    lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    # shlex reads `#` as a comment anywhere, which would turn `nix run .#grow -- dev up` into
    # `nix run .`; keeping it a word char can only make the hook see more.
    lexer.commenters = ""
    try:
        tokens = list(lexer)
    except ValueError as exc:
        raise Refused(f"unparseable command: {exc}") from exc
    commands, current, skip_next = [], [], False
    for tok in tokens:
        if skip_next:
            skip_next = False
            continue
        if tok in SEPARATORS:
            if current:
                commands.append(current)
            current = []
            continue
        if REDIRECTS.match(tok):
            skip_next = True
            if current and current[-1].isdigit():
                current.pop()
            continue
        current.append(tok)
    if current:
        commands.append(current)
    return commands


def positionals(args, value_opts, arity=None):
    arity = arity or {}
    out, i = [], 0
    while i < len(args):
        tok = args[i]
        if tok == "--":
            out.extend(args[i + 1:])
            break
        if tok.startswith("--"):
            if "=" not in tok and tok in value_opts:
                i += arity.get(tok, 1)
        elif tok.startswith("-") and len(tok) > 1:
            if tok in value_opts:
                i += arity.get(tok, 1)
        else:
            out.append(tok)
        i += 1
    return out


def skip_options(args, value_opts):
    """Index of the first non-option word in ARGS (after any `--`)."""
    i = 0
    while i < len(args):
        tok = args[i]
        if tok == "--":
            return i + 1
        if not tok.startswith("-") or tok == "-":
            return i
        if "=" not in tok and tok in value_opts:
            i += 1
        i += 1
    return i


class Analyzer:
    def __init__(self, table, cwd, home):
        self.table = table
        self.cwd = cwd
        self.home = home
        self.verdicts = []

    def deny(self, why, argv):
        self.verdicts.append(("deny", f"{why}: {' '.join(argv)}"))

    def ask(self, why, argv):
        self.verdicts.append(("ask", f"{why}: {' '.join(argv)}"))

    def analyze(self, text, depth=0):
        if depth > MAX_DEPTH:
            raise Refused("wrapping nested deeper than the hook follows")
        outer, bodies = extract_substitutions(text)
        for body in bodies:
            self.analyze(body, depth + 1)
        for argv in simple_commands(outer):
            self.unwrap(argv, depth)

    def unwrap(self, argv, depth):
        while argv:
            while argv and (ASSIGNMENT.match(argv[0]) or argv[0] in KEYWORDS):
                argv = argv[1:]
            if not argv:
                return
            prog = os.path.basename(argv[0])
            rest = argv[1:]
            nxt = self.peel(prog, rest, depth)
            if nxt is None:
                self.check([prog] + rest)
                return
            argv = nxt

    def peel(self, prog, rest, depth):
        """The wrapped command line inside PROG REST, [] when there is none, None if PROG is not a wrapper."""
        if prog in ("sudo", "doas"):
            return rest[skip_options(rest, {"-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-U", "-T",
                                             "--user", "--group", "--host", "--prompt"}):]
        if prog == "env":
            i = 0
            while i < len(rest):
                tok = rest[i]
                if tok in ("-S", "--split-string") and i + 1 < len(rest):
                    self.analyze(rest[i + 1] + " " + " ".join(shlex.quote(a) for a in rest[i + 2:]), depth + 1)
                    return []
                if tok.startswith("--split-string="):
                    self.analyze(tok.split("=", 1)[1], depth + 1)
                    return []
                if tok in ("-u", "--unset", "-C", "--chdir"):
                    i += 2
                elif tok.startswith("-") or ASSIGNMENT.match(tok):
                    i += 1
                else:
                    break
            return rest[i:]
        if prog in ("nohup", "time", "command", "builtin", "noglob", "nocorrect", "setsid", "unbuffer"):
            if prog == "command" and rest[:1] and rest[0] in ("-v", "-V"):
                return []
            return rest[skip_options(rest, {"-a"}):]
        if prog == "exec":
            return rest[skip_options(rest, {"-a"}):]
        if prog == "nice":
            return rest[skip_options(rest, {"-n", "--adjustment"}):]
        if prog == "ionice":
            return rest[skip_options(rest, {"-c", "-n", "-p", "-P", "-u", "--class", "--classdata"}):]
        if prog == "stdbuf":
            return rest[skip_options(rest, {"-i", "-o", "-e"}):]
        if prog == "timeout":
            i = skip_options(rest, {"-s", "--signal", "-k", "--kill-after"})
            return rest[i + 1:]
        if prog == "caffeinate":
            return rest[skip_options(rest, {"-t", "-w"}):]
        if prog == "xargs":
            return rest[skip_options(rest, {"-n", "-L", "-l", "-I", "-i", "-P", "-d", "-E", "-e", "-s", "-a",
                                             "--max-args", "--max-lines", "--max-procs", "--delimiter",
                                             "--arg-file", "--replace"}):]
        if prog == "watch":
            i = skip_options(rest, {"-n", "--interval", "-d", "-q"})
            self.analyze(" ".join(rest[i:]), depth + 1)
            return []
        if prog == "eval":
            self.analyze(" ".join(rest), depth + 1)
            return []
        if prog in SHELLS:
            for i, tok in enumerate(rest):
                if tok.startswith("-") and not tok.startswith("--") and "c" in tok[1:]:
                    if i + 1 < len(rest):
                        self.analyze(rest[i + 1], depth + 1)
                    return []
                if not tok.startswith("-"):
                    break
            return []
        if prog == "ssh":
            i = skip_options(rest, set("-b -c -D -E -e -F -I -i -J -L -l -m -O -o -p -Q -R -S -W -w -B".split()))
            if i + 1 < len(rest):
                self.analyze(" ".join(rest[i + 1:]), depth + 1)
            return []
        if prog == "flox":
            if not rest or rest[0] != "activate":
                return None
            args, i = rest[1:], 0
            while i < len(args):
                tok = args[i]
                if tok == "--":
                    return args[i + 1:]
                if tok in ("-c", "--command"):
                    if i + 1 < len(args):
                        self.analyze(args[i + 1], depth + 1)
                    return []
                i += 2 if tok in ("-d", "--dir", "-r", "--remote", "-m", "--mode", "--generation") else 1
            return []
        if prog == "nix-shell":
            for i, tok in enumerate(rest):
                if tok in ("--run", "--command") and i + 1 < len(rest):
                    self.analyze(rest[i + 1], depth + 1)
            return []
        if prog == "nix":
            return self.peel_nix(rest)
        return None

    NIX_ARITY = {"--override-input": 2, "--option": 2, "--arg": 2, "--argstr": 2}
    NIX_VALUE = {"-I", "--inputs-from", "--profile", "--expr", "-f", "--file", "--override-input",
                 "--option", "--arg", "--argstr", "--store", "--eval-store", "--include"}

    def peel_nix(self, rest):
        if not rest or rest[0] not in ("run", "shell", "develop"):
            return None
        sub, args = rest[0], rest[1:]
        if sub == "run":
            if "--" in args:
                cut = args.index("--")
                before, after = args[:cut], args[cut + 1:]
            else:
                before, after = args, None
            pos = positionals(before, self.NIX_VALUE, self.NIX_ARITY)
            if not pos:
                return []
            attr = pos[0].split("#", 1)[1] if "#" in pos[0] else pos[0]
            name = attr.rsplit(".", 1)[-1] if "#" in pos[0] else os.path.basename(attr)
            name = self.table.get("nix_attr_aliases", {}).get(name, name)
            return [name] + (after if after is not None else pos[1:])
        for flag in ("-c", "--command"):
            if flag in args:
                return args[args.index(flag) + 1:]
        return []

    def is_claude_path(self, tok):
        if CLAUDE_DIR.match(tok):
            return True
        if self.cwd and os.path.normpath(self.cwd) == os.path.normpath(self.home):
            return bool(re.match(r"^(?:\./)?\.claude(?:$|[./_-])", tok))
        return tok.startswith(self.home.rstrip("/") + "/.claude")

    def is_claude_config(self, tok):
        """A Claude path outside ~/.claude/.scratchpad.d, the one place under it a session files its own scratch."""
        if not self.is_claude_path(tok):
            return False
        path = self.resolve(re.sub(r"^\$(?:HOME|\{HOME\})(?=/|$)", "~", tok))
        scratch = os.path.join(os.path.normpath(self.home), ".claude", ".scratchpad.d")
        return path is None or not (path == scratch or path.startswith(scratch + os.sep))

    def resolve(self, tok):
        """TOK as an absolute normalised path, or None when the shell would expand it."""
        if re.search(r"[$`*?\[\]{}]", tok):
            return None
        if tok == "~" or tok.startswith("~/"):
            tok = self.home + tok[1:]
        elif tok.startswith("~"):
            return None
        if not os.path.isabs(tok):
            if not self.cwd:
                return None
            tok = os.path.join(self.cwd, tok)
        return os.path.normpath(tok)

    def is_scratch_target(self, tok):
        path = self.resolve(tok)
        if path is None:
            return False
        if ".scratchpad.d" in path.split(os.sep)[:-1] or path.endswith(os.sep + ".scratchpad.d"):
            return True
        roots = ["/tmp", "/private/tmp"] + [os.path.normpath(os.environ["TMPDIR"])] * ("TMPDIR" in os.environ)
        return any(path.startswith(r.rstrip("/") + "/") for r in roots)

    def is_dangerous_root(self, tok):
        if tok in ("$HOME", "${HOME}", '"$HOME"'):
            return True
        path = self.resolve(tok)
        if path is None:
            return False
        home = os.path.normpath(self.home)
        return (path.count("/") <= 1 or path == home or home.startswith(path.rstrip("/") + "/")
                or path == "/nix" or path.startswith("/nix/"))

    def check(self, argv):
        prog, args = argv[0], argv[1:]
        if prog == "rm":
            flags = "".join(t[1:] for t in args if t.startswith("-") and not t.startswith("--"))
            recursive = bool(set(flags) & {"r", "R"}) or "--recursive" in args
            force = "f" in flags or "--force" in args
            targets = [t for t in args if not t.startswith("-")]
            if not recursive or not targets:
                return
            if any(self.is_claude_path(t) or self.is_dangerous_root(t) for t in targets):
                self.ask("recursive removal of the Claude config or a top-level directory", argv)
            elif force and not all(self.is_scratch_target(t) for t in targets):
                self.ask("recursive forced removal outside a scratch directory", argv)
            return
        if prog == "mv":
            if any(self.is_claude_config(t) for t in args if not t.startswith("-")):
                self.deny("moves the Claude config", argv)
            return
        spec = self.table["programs"].get(prog)
        if spec:
            pos = positionals(args, set(spec.get("value_opts", [])))
            if any(v in pos[:spec.get("window", 1)] for v in spec["verbs"]):
                self.deny(f"mutating {prog} verb", argv)
                return
            if any(v in pos[:spec.get("nested_window", 0)] for v in spec.get("nested_verbs", [])):
                self.deny(f"mutating {prog} sub-verb", argv)
                return
            if any(f in args for f in spec.get("flag_verbs", [])):
                self.deny(f"mutating {prog} flag", argv)
            return
        for launcher in self.table.get("ask_launchers", []):
            if prog != launcher["program"]:
                continue
            joined = " ".join(args)
            if all(s in joined for s in launcher.get("all_args_contain", [])) and \
                    any(s in joined for s in launcher.get("any_arg_contains", [""])):
                self.ask("seed run whose live/preview mode is decided inside the JVM, not in this text", argv)


def main():
    try:
        event = json.load(sys.stdin)
        if event.get("tool_name") != "Bash":
            return 0
        command = event.get("tool_input", {}).get("command")
        if not isinstance(command, str):
            raise Refused("no command text to inspect")
        analyzer = Analyzer(load_table(), event.get("cwd") or "", os.environ.get("HOME") or os.path.expanduser("~"))
        analyzer.analyze(command)
    except Refused as exc:
        print(f"deny-hook refused: {exc}", file=sys.stderr)
        return 2
    except Exception as exc:  # fail closed: a PreToolUse hook that errors would otherwise let the call through
        print(f"deny-hook internal error, refusing: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2
    denies = [why for kind, why in analyzer.verdicts if kind == "deny"]
    if denies:
        print("deny-hook refused — run it yourself if intended: " + "; ".join(denies), file=sys.stderr)
        return 2
    asks = [why for kind, why in analyzer.verdicts if kind == "ask"]
    if asks:
        json.dump({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask",
                                          "permissionDecisionReason": "; ".join(asks)}}, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
