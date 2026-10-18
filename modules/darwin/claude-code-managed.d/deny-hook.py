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

import fnmatch
import json
import os
import re
import shlex
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
MAX_DEPTH = 8

SEPARATORS = {"&&", "||", "|", "|&", ";", "&", ";;", "(", ")"}
KEYWORDS = {"if", "then", "else", "elif", "fi", "do", "done", "while", "until", "for", "case",
            "esac", "!", "{", "}", "function", "select", "in"}
REDIRECTS = re.compile(r"^\d*(?:<<<|<<-|<<|>>|>&|<&|&>>|&>|>\||<>|<|>)$")
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "fish"}
# The variables through which the session's git config is made sops-neutral (sops-git-env.sh).
GIT_ENV = re.compile(r"^GIT_CONFIG(?:_COUNT|_KEY_\d+|_VALUE_\d+|_PARAMETERS|_GLOBAL|_SYSTEM|_NOSYSTEM)?$")
CLAUDE_DIR = re.compile(r"^(?:~|\$\{?HOME\}?|/(?:Users|home)/[^/]+|/var/root)/\.claude(?:$|[./_-])")


class Refused(Exception):
    """A structural reason to refuse without looking further (too deep, unparseable)."""


def load_table():
    with open(os.path.join(HERE, "verbs.json"), encoding="utf-8") as fh:
        return json.load(fh)


def load_owned():
    """The deletion areas security engraved (owned-dirs.yaml, built into the owned-dirs.json beside this file); none when it is absent."""
    path = os.path.join(HERE, "owned-dirs.json")
    if not os.path.exists(path):
        return {"sessions": {}, "global_exclude": [], "pages_never_remove": []}
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def expand_braces(pattern):
    """{a,b} and {1..8} into exact alternatives, as the registry's syntax allows."""
    m = re.search(r"\{([^{}]*)\}", pattern)
    if not m:
        return [pattern]
    body = m.group(1)
    rng = re.fullmatch(r"(\d+)\.\.(\d+)", body)
    alts = [str(i) for i in range(int(rng.group(1)), int(rng.group(2)) + 1)] if rng else body.split(",")
    return [x for a in alts for x in expand_braces(pattern[:m.start()] + a + pattern[m.end():])]


def segment_rx(seg):
    return re.compile("^" + "".join("[^/]*" if c == "*" else re.escape(c) for c in seg) + "$")


def match_segments(pat, path):
    """`*` is one segment (or part of one), `**` any number of segments, including none."""
    if not pat:
        return not path
    if pat[0] == "**":
        return any(match_segments(pat[1:], path[i:]) for i in range(len(path) + 1))
    return bool(path) and bool(segment_rx(pat[0]).match(path[0])) and match_segments(pat[1:], path[1:])


def could_hold(pat, path):
    """Whether a path the pattern matches could lie strictly below PATH (so removing PATH would take it)."""
    if not path:
        return bool(pat)
    if not pat:
        return False
    if pat[0] == "**":
        return True
    return bool(segment_rx(pat[0]).match(path[0])) and could_hold(pat[1:], path[1:])


def protected_paths(table, home):
    """The absolute paths of list_path_rules: the managed list's Read()/Edit() rules govern the file
    tools only, so the hook refuses a Bash command reaching them. One source for both."""
    paths = set()
    for entry in table.get("list_path_rules", []):
        m = re.fullmatch(r"(?:Read|Edit)\((/|~)(/[^()\s]+?)(?:/\*\*)?\)", entry["rule"])
        if m and "*" not in m.group(2):
            paths.add(os.path.normpath((home if m.group(1) == "~" else "") + m.group(2)))
    return sorted(paths)


def protected_globs(table, home):
    """The list_path_rules whose path holds a wildcard before its last segment, `//**/.pulumi-state/**`: as segment
    lists for match_segments, each ending in `**` so that the directory and everything under it match."""
    globs = set()
    for entry in table.get("list_path_rules", []):
        m = re.fullmatch(r"(?:Read|Edit)\((/|~)(/[^()\s]+?)(?:/\*\*)?\)", entry["rule"])
        if m and "*" in m.group(2):
            root = (home if m.group(1) == "~" else "") + m.group(2)
            globs.add(tuple(root.strip("/").split("/")) + ("**",))
    return sorted(globs)


def expand_glob(pattern, stop=None):
    """Every existing path PATTERN could expand to, hidden names included: wider than the shell's default, so a
    `.p*` or `*` spelling of a protected directory is seen whatever the shell options. With STOP, the walk ends at
    the first INTERMEDIATE path STOP accepts, and returns it alone: a protected directory is never listed, and what
    lies below it (absent, or unreadable) does not matter."""
    paths = ["/"]
    for seg in pattern.strip("/").split("/"):
        found = []
        for base in paths:
            if not re.search(r"[*?\[]", seg):
                cand = os.path.join(base, seg)
                if os.path.lexists(cand):
                    found.append(cand)
                continue
            try:
                names = os.listdir(base)
            except OSError:
                continue
            found += [os.path.join(base, n) for n in names if fnmatch.fnmatchcase(n, seg)]
        paths = found[:512]
        if stop is not None:
            hit = next((p for p in paths if stop(os.path.normpath(p))), None)
            if hit is not None:
                return [hit]
        if not paths:
            break
    return paths


def spellings(path, home):
    """The ways a command text names PATH: under the home, its ~ and $HOME forms too."""
    home = os.path.normpath(home)
    if not path.startswith(home + os.sep):
        return [path]
    rest = path[len(home):]
    return [path, "~" + rest, "$HOME" + rest, "${HOME}" + rest]


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
    def __init__(self, table, cwd, home, owned=None, session_id=""):
        self.table = table
        self.cwd = cwd
        self.cwd_lost = False
        self.order_unknown = False
        self.home_tainted = False
        self.cdpath_set = False
        self.home = home
        self.owned = owned or {"sessions": {}, "global_exclude": [], "pages_never_remove": []}
        self.session_id = session_id
        self.session = next((name for name, s in self.owned["sessions"].items()
                             if session_id and session_id in s.get("conversations", [])), None)
        self.owned_removals = []
        self.other_commands = 0
        self.protected = protected_paths(table, home)
        self.protected_globs = protected_globs(table, home)
        self._existing = None
        self.verdicts = []
        self.git_env_reset = False
        self.git_env_tainted = False

    def deny(self, why, argv):
        self.verdicts.append(("deny", f"{why}: {' '.join(argv)}"))

    def ask(self, why, argv):
        self.verdicts.append(("ask", f"{why}: {' '.join(argv)}"))

    def analyze(self, text, depth=0):
        if depth > MAX_DEPTH:
            raise Refused("wrapping nested deeper than the hook follows")
        outer, bodies = extract_substitutions(text)
        # A substitution runs a command of its own: never beside an owned removal.
        self.other_commands += len(bodies)
        for body in bodies:
            self.analyze(body, depth + 1)
        for argv in simple_commands(outer):
            self.unwrap(argv, depth)

    # The sessions' gated verbs: a copy outside the store could run anything under their name.
    NDH_VERBS = ("ndh-switch", "fleet-switch", "ndh-ops", "ndh-claude-wake")
    NDH_SWITCH_HOMES = ("/nix/store/", "/run/current-system/sw/bin/", "/etc/profiles/per-user/")

    def unwrap(self, argv, depth):
        # The assignments in front of the command, kept for check(): GIT_CONFIG_GLOBAL=/dev/null drops the
        # global hooks and sops filters of the git command it prefixes.
        self.assignments = []
        saved = self.git_env_reset
        try:
            self.unwrap_chain(argv, depth)
        finally:
            self.git_env_reset = saved

    def unwrap_chain(self, argv, depth):
        while argv:
            # A loop or a function runs its body any number of times, in any order: from there on, a cd is never
            # followed, since textual order is not execution order.
            if argv[0] in ("for", "while", "until", "select", "function") or argv[1:2] == ["()"]:
                self.order_unknown = True
                # A definition's name is not a command: its body is analysed as what it runs.
                if argv[0] == "function":
                    argv = argv[2:]
                elif argv[1:2] == ["()"]:
                    argv = argv[2:]
            while argv and (ASSIGNMENT.match(argv[0]) or argv[0] in KEYWORDS):
                if ASSIGNMENT.match(argv[0]):
                    self.assignments.append(argv[0])
                    self.note_env(argv[0])
                argv = argv[1:]
            if not argv:
                return
            prog = os.path.basename(argv[0])
            rest = argv[1:]
            if prog in self.NDH_VERBS and "/" in argv[0] and not argv[0].startswith(self.NDH_SWITCH_HOMES):
                self.deny(f"{prog} is trusted only as installed by ndh (the store or the system profile)", argv)
                return
            nxt = self.peel(prog, rest, depth)
            if nxt is not None:
                # A launcher (bash -c, sudo, env, ssh, nix run…) is not a plain removal either.
                self.other_commands += 1
            if nxt is None:
                self.check([prog] + rest)
                return
            argv = nxt

    def peel(self, prog, rest, depth):
        """The wrapped command line inside PROG REST, [] when there is none, None if PROG is not a wrapper."""
        if prog in ("sudo", "doas"):
            # Their environment is reset: the session's sops-neutral git config is gone.
            self.git_env_reset = True
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
                if tok in ("-C", "--chdir") or tok.startswith(("--chdir=", "-C")) and tok != "-C":
                    # env moves the cwd of the command it runs, like a cd before it.
                    attached = tok.startswith("--chdir=") or (tok.startswith("-C") and tok != "-C")
                    target = tok.split("=", 1)[1] if tok.startswith("--chdir=") else tok[2:] if attached else (
                        rest[i + 1] if i + 1 < len(rest) else "")
                    self.move_cwd(target)
                    i += 1 if attached else 2
                elif tok in ("-i", "-", "--ignore-environment"):
                    self.git_env_reset = True
                    i += 1
                elif tok in ("-u", "--unset") or tok.startswith(("-u", "--unset=")):
                    name = rest[i + 1] if tok in ("-u", "--unset") and i + 1 < len(rest) else tok.split("=", 1)[1] if \
                        tok.startswith("--unset=") else tok[2:]
                    if GIT_ENV.match(name):
                        self.git_env_reset = True
                    i += 2 if tok in ("-u", "--unset") else 1
                elif ASSIGNMENT.match(tok):
                    self.assignments.append(tok)
                    self.note_env(tok)
                    i += 1
                elif tok.startswith("-"):
                    i += 1
                else:
                    break
            return rest[i:]
        if prog in ("nohup", "time", "command", "builtin", "noglob", "nocorrect", "setsid", "unbuffer"):
            if prog == "command" and rest[:1] and rest[0] in ("-v", "-V"):
                return []
            return rest[skip_options(rest, {"-a"}):]
        if prog == "exec":
            i = skip_options(rest, {"-a"})
            # bash's `exec -c` runs the command with an empty environment.
            if any(t.startswith("-") and not t.startswith("--") and "c" in t[1:] for t in rest[:i] if t != "-a"):
                self.git_env_reset = True
            return rest[i:]
        if prog == "script":
            # util-linux: `script -c CMD [file]`; BSD: `script [opts] [file [command …]]`.
            for k, tok in enumerate(rest):
                if tok in ("-c", "--command") and k + 1 < len(rest):
                    self.analyze(rest[k + 1], depth + 1)
                    return []
                if tok.startswith("--command="):
                    self.analyze(tok.split("=", 1)[1], depth + 1)
                    return []
            i = skip_options(rest, {"-t", "-T", "-F", "-I", "-O", "-B", "-E", "-m", "--timing", "--log-in",
                                    "--log-out", "--log-io", "--log-timing", "--echo", "--logging-format"})
            return rest[i + 1:]
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
            inner = rest[skip_options(rest, {"-n", "-L", "-l", "-I", "-i", "-P", "-d", "-E", "-e", "-s", "-a",
                                              "--max-args", "--max-lines", "--max-procs", "--delimiter",
                                              "--arg-file", "--replace"}):]
            # Its targets come on stdin, which the hook never sees: a remover fed that way is judged blind.
            if inner and os.path.basename(inner[0]) in self.FIND_REMOVERS - SHELLS:
                self.deny("a removal fed by xargs, whose targets the hook cannot see; name the paths", ["xargs"] + rest)
                return []
            return inner
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
        launched = self.launched(prog, rest)
        if launched is not None:
            # The launcher's own argv is judged too: `incus exec` stays a gated verb whatever it runs.
            self.check([prog] + rest)
            where, inner = launched
            if where == "here":
                return inner
            if inner:
                # It runs elsewhere (a VM, a pod, a container, a chroot): judged like an ssh remote command.
                self.analyze(" ".join(shlex.quote(a) for a in inner), depth + 1)
            elif where == "shell":
                self.ask(f"an interactive shell through {prog}, which the hook cannot see into", [prog] + rest)
            return []
        if prog == "ssh":
            i = skip_options(rest, set("-b -c -D -E -e -F -I -i -J -L -l -m -O -o -p -Q -R -S -W -w -B".split()))
            if i < len(rest) and self.names_vz_recover(rest[i]):
                self.check_vz_recover(rest[:i], rest[i + 1:], ["ssh"] + rest)
                return []
            why = self.ssh_override(rest[:i])
            if why:
                self.deny(f"{why}: {self.table['vz_recover']['why']}", ["ssh"] + rest)
                return []
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

    def names_vz_recover(self, tok):
        """Whether TOK spells the vz-recover host or key in any form a client config could map: the
        alias, a variant of it, the key's file under any path or case."""
        spec = self.table.get("vz_recover")
        return bool(spec) and re.search(spec["key_spelling"], tok) is not None

    def ssh_override(self, opts):
        """Why an ssh toward any other host is refused: an option naming the vz-recover key or host, an
        alternate config (-F, -o Include) that could map the key, or an identity given by a glob."""
        i = 0
        while i < len(opts):
            tok = opts[i]
            value = opts[i + 1] if tok in ("-i", "-F", "-o", "-J") and i + 1 < len(opts) else tok[2:]
            if self.names_vz_recover(tok) or self.names_vz_recover(value):
                return f"ssh option {tok} names vz-recover"
            if tok.startswith("-F") or (tok.startswith("-o") and re.match(r"(?i)\s*include\b", value)):
                return "an alternate ssh config could map the vz-recover key"
            if (tok.startswith("-i") or (tok.startswith("-o") and re.match(r"(?i)\s*(identityfile|certificatefile)\b", value))) \
                    and re.search(r"[*?\[]", value):
                return "an ssh identity given by a glob"
            i += 2 if tok in ("-i", "-F", "-o", "-J") else 1
        return None

    def check_vz_recover(self, opts, remote, argv):
        """The vz-recover key is a forced command on the operator's corporate account, and the guard must hold even
        when the server's line lost its `restrict,command=` (2026-10-17): only the wrapper's verbs, one VM name at
        most, no forwarding, no option beyond a few harmless ones."""
        spec = self.table["vz_recover"]
        allowed = {k.lower() for k in spec["options"]}
        # The client's own multiplexing master: closing it after a line change must stay possible, and it runs nothing there.
        control = [t for t in opts if t != "--"]
        if control[:1] == ["-O"] and len(control) == 2 or len(control) == 1 and control[0].startswith("-O"):
            command = control[1] if control[0] == "-O" else control[0][2:]
            if command in spec["control_commands"] and not remote:
                return
            self.deny(f"ssh -O {command} toward vzrecover.*: {spec['why']}", argv)
            return
        i = 0
        while i < len(opts):
            tok = opts[i]
            if tok == "--":
                i += 1
                continue
            if tok == "-o" or tok.startswith("-o"):
                value = (opts[i + 1] if i + 1 < len(opts) else "") if tok == "-o" else tok[2:]
                if re.split(r"[=\s]", value.strip(), maxsplit=1)[0].lower() not in allowed:
                    self.deny(f"ssh option {value!r} toward vzrecover.*: {spec['why']}", argv)
                    return
                i += 2 if tok == "-o" else 1
                continue
            if not re.fullmatch("-[" + re.escape(spec["flags"]) + "]+", tok):
                self.deny(f"ssh option {tok} toward vzrecover.*: {spec['why']}", argv)
                return
            i += 1
        # ssh joins the remote words with spaces and the far side splits them again, so judge the joined words.
        words = " ".join(remote).split()
        if "__subst__" in words or any("__subst__" in tok for tok in opts):
            self.deny(f"a substitution in a call toward vzrecover.*: {spec['why']}", argv)
            return
        if (not words or words[0] not in spec["verbs"] or len(words) > 2
                or (words[0] in spec.get("bare_verbs", []) and len(words) > 1)
                or not all(re.fullmatch(spec["arg"], w) for w in words[1:])):
            self.deny(f"remote command {' '.join(remote)!r} toward vzrecover.*: {spec['why']}", argv)

    def launched(self, prog, rest):
        """A launcher that runs a command elsewhere or as another context: ("away", argv) for a VM, a pod, a container
        or a chroot; ("here", argv) for a local one (nsenter, systemd-run); ("shell", []) for an interactive shell;
        None when PROG launches nothing."""
        def after(i):
            return rest[i:] if i < len(rest) else []
        if prog == "tart" and rest[:1] == ["exec"]:
            i = 1 + skip_options(rest[1:], set())
            return ("away", after(i + 1)) if i < len(rest) else None
        if prog == "kubectl":
            value_opts = {"-n", "--namespace", "--context", "--kubeconfig", "--cluster", "--user", "-c", "--container",
                          "-s", "--server", "--token", "-f", "--filename", "--pod-running-timeout"}
            if positionals(rest, value_opts)[:1] != ["exec"]:
                return None
            if "--" in rest:
                return ("away", rest[rest.index("--") + 1:])
            # The old form, with no `--`: the command is all that follows the pod, its own flags kept.
            seen, j = 0, 0
            while j < len(rest) and seen < 2:
                tok = rest[j]
                if tok.startswith("-"):
                    j += 2 if "=" not in tok and tok in value_opts else 1
                    continue
                seen += 1
                j += 1
            return ("away", rest[j:])
        if prog in ("docker", "podman") and rest[:1] == ["exec"]:
            i = 1 + skip_options(rest[1:], {"-u", "--user", "-w", "--workdir", "-e", "--env", "--env-file",
                                            "--detach-keys"})
            return ("away", after(i + 1)) if i < len(rest) else None
        if prog == "chroot":
            i = skip_options(rest, {"--userspec", "--groups"})
            return (("away", after(i + 1)) if after(i + 1) else ("shell", [])) if i < len(rest) else None
        if prog == "incus" and rest[:1] in (["exec"], ["shell"]):
            i = 1 + skip_options(rest[1:], {"--project", "--target", "--env", "--cwd", "--user", "--group", "--mode"})
            if rest[0] == "shell":
                return ("shell", [])
            tail = rest[rest.index("--", i) + 1:] if "--" in rest[i:] else after(i + 1)
            return ("away", tail) if i < len(rest) else None
        if prog == "machinectl" and rest[:1] in (["shell"], ["login"]):
            pos = [a for a in rest[1:] if not a.startswith("-")]
            return ("away", pos[1:]) if len(pos) > 1 else ("shell", [])
        if prog == "nsenter":
            return ("here", after(skip_options(rest, {"-t", "--target", "-S", "--setuid", "-G", "--setgid",
                                                       "-w", "--wd", "-r", "--root"})))
        if prog == "systemd-run":
            return ("here", after(skip_options(rest, {"-u", "--unit", "-p", "--property", "-E", "--setenv", "--uid",
                                                       "--gid", "-M", "--machine", "-H", "--host", "--description",
                                                       "--slice", "--working-directory", "-d"})))
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

    def move_cwd(self, target):
        """A cd to TARGET: followed when it resolves, the cwd lost otherwise (None, inside a loop or a function)."""
        moved = None if target is None or self.order_unknown else self.resolve(target)
        if moved:
            self.cwd = moved
        else:
            self.cwd, self.cwd_lost = "", True
        return moved

    def note_env(self, tok):
        """An assignment (or an export/unset name) that changes how cd moves: HOME is what ~, $HOME and a bare cd
        expand to, and CDPATH sends a relative cd elsewhere. Once either is touched, the hook no longer trusts them."""
        name = tok.split("=", 1)[0]
        if GIT_ENV.match(name):
            # The session's git env holds the sops-neutral config: once rewritten, a later git may decrypt.
            self.git_env_tainted = True
        if name == "HOME":
            self.home_tainted = True
        elif name == "CDPATH":
            self.cdpath_set = True

    def is_claude_path(self, tok):
        if CLAUDE_DIR.match(tok):
            return True
        if self.cwd and os.path.normpath(self.cwd) == os.path.normpath(self.home):
            return bool(re.match(r"^(?:\./)?\.claude(?:$|[./_-])", tok))
        if tok.startswith(self.home.rstrip("/") + "/.claude"):
            return True
        # A relative path, against the cwd the cd chain left: `cd ~/.claude && rm -rf settings.json`.
        path, home = self.resolve(tok), os.path.normpath(self.home)
        return bool(path and path.startswith(home + os.sep) and CLAUDE_DIR.match("~" + path[len(home):]))

    def is_claude_config(self, tok):
        """A Claude path outside ~/.claude/.scratchpad.d, the one place under it a session files its own scratch."""
        if not self.is_claude_path(tok):
            return False
        path = self.resolve(re.sub(r"^\$(?:HOME|\{HOME\})(?=/|$)", "~", tok))
        scratch = os.path.join(os.path.normpath(self.home), ".claude", ".scratchpad.d")
        return path is None or not (path == scratch or path.startswith(scratch + os.sep))

    def resolve(self, tok):
        """TOK as an absolute normalised path, or None when the shell would expand it."""
        # $HOME is the one variable whose value the hook knows: a session writes `cd "$HOME/…"` as often as `cd ~/…`.
        tok = re.sub(r"^\$(?:HOME|\{HOME\})(?=/|$)", "~", tok)
        # A substitution was replaced by a neutral word (extract_substitutions): its value is unknown. So is ~ once the
        # command assigns HOME.
        if re.search(r"[$`*?\[\]{}]", tok) or "__subst__" in tok or (self.home_tainted and tok.startswith("~")):
            return None
        if tok == "~" or tok.startswith("~/"):
            tok = self.home + tok[1:]
        elif tok.startswith("~"):
            # ~user: only the home's own owner is known; ~+ and ~- are the directory stack.
            user, _, below = tok[1:].partition("/")
            if user != os.path.basename(os.path.normpath(self.home)):
                return None
            tok = self.home + ("/" + below if below else "")
        if not os.path.isabs(tok):
            if not self.cwd:
                return None
            tok = os.path.join(self.cwd, tok)
        return os.path.normpath(tok)

    def is_protected(self, path):
        if path is None:
            return False
        segs = path.strip("/").split("/")
        return (any(path == p or path.startswith(p + os.sep) for p in self.protected)
                or any(match_segments(list(g), segs) for g in self.protected_globs))

    def reaches_protected(self, tok):
        """TOK, an option's value included, resolved against the tracked cwd; a glob is cut at its first
        wildcard, so `keyring/*` still names keyring."""
        tok = tok.split("=", 1)[1] if tok.startswith("-") and "=" in tok else tok
        stem = re.split(r"[*?\[]", tok, maxsplit=1)[0]
        if self.is_protected(self.resolve(tok)) or (stem != tok and self.is_protected(self.resolve(stem.rstrip("/") or "/"))):
            return True
        if stem != tok:
            pattern = self.glob_pattern(tok)
            return pattern is not None and any(
                self.is_protected(os.path.normpath(m)) for m in expand_glob(pattern, stop=self.is_protected))
        return False

    def glob_pattern(self, tok):
        """TOK, a glob, as an absolute pattern: ~ and $HOME read as the home, a relative one against the tracked
        cwd; None when the shell would expand something else first (a variable, a substitution) or the cwd is lost."""
        tok = re.sub(r"^\$(?:HOME|\{HOME\})(?=/|$)", "~", tok)
        if "$" in tok or "`" in tok or "__subst__" in tok or (self.home_tainted and tok.startswith("~")):
            return None
        if tok == "~" or tok.startswith("~/"):
            return self.home + tok[1:]
        if os.path.isabs(tok):
            return tok
        return os.path.join(self.cwd, tok) if self.cwd else None

    def existing_protected_dirs(self):
        """The directories that match a protected glob and exist, found once per call. They sit at worktree roots,
        and every bare repository lists its worktrees (worktrees/*/gitdir): read those small files, then look only at
        each worktree root's direct children. A walk of the disk took seconds."""
        if self._existing is not None:
            return self._existing
        found = []
        for root in self.table.get("protected_scan_bares", []):
            root = self.home + root[1:] if root.startswith("~") else root
            repos = []
            for pattern in ("*.git", "*/*.git"):
                repos += expand_glob(os.path.join(root, pattern))
            for repo in repos:
                for gitdir in expand_glob(os.path.join(repo, "worktrees", "*", "gitdir")):
                    try:
                        with open(gitdir, encoding="utf-8") as fh:
                            worktree = os.path.dirname(fh.read().strip())
                        children = [e.path for e in os.scandir(worktree) if e.is_dir(follow_symlinks=False)]
                    except OSError:
                        continue
                    found += [c for c in children if self.is_protected(c)]
        self._existing = found
        return found

    # A reader that walks a tree: the roots it walks, judged against the protected directories that exist below them.
    TREE_READERS = {"grep", "egrep", "fgrep", "rg", "tar", "cp", "rsync", "scp", "zip", "ditto", "find", "git"}
    CONTENT_PROGRAMS = {"cat", "grep", "egrep", "head", "tail", "less", "more", "strings", "xxd", "od", "base64",
                        "cp", "tar", "sh", "bash", "zsh", "jq", "yq", "python3", "awk", "sed"}

    def tree_roots(self, prog, args):
        """The roots PROG walks recursively, or [] when it does not walk (a plain grep, a cp without -r)."""
        flags = [a for a in args if a.startswith("-")]
        pos = [a for a in args if not a.startswith("-")]
        short = "".join(f[1:] for f in flags if not f.startswith("--"))
        if prog in ("grep", "egrep", "fgrep"):
            if not ("r" in short or "R" in short or any(f in ("--recursive", "--dereference-recursive") for f in flags)):
                return []
            pattern_given = any(f in ("-e", "-f") or f.startswith(("--regexp", "--file")) for f in flags)
            return (pos if pattern_given else pos[1:]) or ["."]
        if prog == "rg":
            if not ("u" in short or any(f.startswith(("--no-ignore", "--hidden")) for f in flags)):
                return []
            return pos[1:] or ["."]
        if prog == "cp":
            return pos[:-1] if ("r" in short or "R" in short or "a" in short or "--recursive" in flags) else []
        if prog in ("scp", "zip"):
            return pos if "r" in short else []
        if prog in ("rsync", "ditto"):
            return pos[:-1]
        if prog == "tar":
            mode = (args[0] if args and not args[0].startswith("-") else "") + short
            return [a for a in pos if os.path.isdir(self.resolve(a) or "")] if "c" in mode else []
        if prog == "find":
            runs = any(a in ("-exec", "-execdir", "-ok", "-okdir") and i + 1 < len(args)
                       and os.path.basename(args[i + 1]) in self.CONTENT_PROGRAMS for i, a in enumerate(args))
            if not runs:
                return []
            starts = []
            for a in args:
                if a.startswith("-") or a in ("(", "!", ")"):
                    break
                starts.append(a)
            return starts or ["."]
        if prog == "git" and "grep" in args and any(f in ("--untracked", "--no-index") for f in flags):
            # The root git works in: -C (chained), --work-tree, else the cwd.
            root, i = ".", 0
            while i < len(args):
                a = args[i]
                if a == "-C" and i + 1 < len(args):
                    root = os.path.join(root, args[i + 1]) if not os.path.isabs(args[i + 1]) else args[i + 1]
                    i += 2
                    continue
                if a.startswith("--work-tree="):
                    root = a.split("=", 1)[1]
                elif a == "--work-tree" and i + 1 < len(args):
                    root = args[i + 1]
                    i += 1
                elif a == "grep":
                    break
                i += 1
            return [root]
        return []

    def walks_into_protected(self, prog, args):
        """Why PROG is refused: a recursive walk whose root holds (or is) an existing protected directory."""
        roots = self.tree_roots(prog, args)
        if not roots:
            return None
        for r in roots:
            path = self.resolve(r)
            if path is None:
                return f"a recursive {prog} from {r}, which the hook cannot resolve; name the absolute path"
            for d in self.existing_protected_dirs():
                if d == path or d.startswith(path.rstrip("/") + "/"):
                    return f"a recursive {prog} from {r} would read {d}"
        return None

    def option_hits(self, args, rule):
        """The first forbidden option of ARGS, and whether ARGS name a command. gpg takes any unique prefix
        of a long option and clusters short ones, so `--decr` and `-qd` are --decrypt; in `-rd` the d is
        -r's value."""
        command, i = False, 0
        while i < len(args):
            tok = args[i]
            i += 1
            if tok == "--":
                break
            if tok.startswith("--") and len(tok) > 2:
                name = tok.split("=", 1)[0]
                if name not in rule["free_long"] and any(f.startswith(name) for f in rule["long"]):
                    return tok, command
                command = command or any(c.startswith(name) for c in rule["commands_long"])
            elif tok.startswith("-") and len(tok) > 1:
                for j, ch in enumerate(tok[1:], start=2):
                    if ch in rule["short"]:
                        return tok, command
                    command = command or ch in rule["commands_short"]
                    if ch in rule["value_short"]:
                        i += j == len(tok)
                        break
        return None, command

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

    def patterns(self, entries):
        return [self.resolve_pattern(x) for e in entries for x in expand_braces(e)]

    def resolve_pattern(self, pattern):
        return os.path.normpath(self.home + pattern[1:]) if pattern == "~" or pattern.startswith("~/") else pattern

    def excluded(self, path):
        """Global, session and page excludes; a target is excluded too when it would take an excluded path with it.
        A pattern that starts with ** (a .secrets anywhere) is looked for on disk below the target."""
        sess = self.owned["sessions"].get(self.session, {})
        entries = self.owned.get("global_exclude", []) + self.owned.get("pages_never_remove", []) + sess.get("exclude", [])
        segs = path.strip("/").split("/")
        for pattern in self.patterns(entries):
            psegs = pattern.strip("/").split("/")
            if match_segments(psegs, segs):
                return pattern
            if psegs[0] == "**":
                tail = psegs[1:]
                # Removing a link leaves what it points at: only a real directory is searched.
                for root, dirs, files in ([] if os.path.islink(path) else os.walk(path)):
                    for name in dirs + files:
                        rel = os.path.relpath(os.path.join(root, name), path).split(os.sep)
                        if match_segments(["**"] + tail, rel):
                            return pattern
            elif could_hold(psegs, segs):
                return pattern
        return None

    def owned_pattern(self, path, key):
        """The session's pattern under KEY that PATH matches strictly below its root, or None."""
        if self.session is None or path is None:
            return None
        segs = path.strip("/").split("/")
        for pattern in self.patterns(self.owned["sessions"][self.session].get(key, [])):
            psegs = pattern.strip("/").split("/")
            # The root of an area (`…/**` itself) is never removed: `**` must stand for one segment at least.
            if psegs[-1] == "**" and len(segs) <= len(psegs) - 1:
                continue
            if match_segments(psegs, segs):
                return pattern
        return None

    def foreign(self, path):
        """Why PATH may not be removed by this session at all: another session's area, or a global exclude."""
        segs = path.strip("/").split("/")
        for pattern in self.patterns(self.owned.get("global_exclude", [])):
            if match_segments(pattern.strip("/").split("/"), segs):
                return f"{path} is excluded for every session"
        for name, sess in self.owned["sessions"].items():
            if name == self.session:
                continue
            for pattern in self.patterns(sess.get("owned", [])):
                psegs = pattern.strip("/").split("/")
                root = psegs[:-1] if psegs[-1] == "**" else None
                if match_segments(psegs, segs) or (root is not None and segs == root):
                    return f"{path} belongs to {name}"
        return None

    def holds_foreign(self, path):
        """Why a walk from PATH would reach another session's area: one of its patterns could lie below PATH."""
        for name, sess in self.owned["sessions"].items():
            if name == self.session:
                continue
            for pattern in self.patterns(sess.get("owned", [])):
                if could_hold(pattern.strip("/").split("/"), path.strip("/").split("/")):
                    return f"{path} holds an area of {name}"
        return None

    def owned_removal(self, key, argv):
        """Record an owned removal: one exact path, in the calling session's area, touching no exclude."""
        if re.search(r"[*?\[\]{}$`]", argv[-1]):
            return False
        resolved = self.resolve(argv[-1])
        if resolved and resolved.startswith("/tmp/") and self.owned_pattern("/private" + resolved, key):
            self.deny("/tmp is a symlink the deletion registry does not name: write /private" + resolved, argv)
            return True
        pattern = self.owned_pattern(resolved, key)
        if pattern is None or self.excluded(resolved):
            return False
        # Symlinks. With a trailing slash rm works on a link's TARGET, so that is never an owned removal. Without one,
        # rm removes the last component itself (a link alone, not what it points at), so the real place is its
        # parent's real path: a symlinked directory on the way must not lead out of the area or into an exclude.
        if argv[-1].endswith("/") and os.path.islink(resolved):
            return False
        real = os.path.join(os.path.realpath(os.path.dirname(resolved)), os.path.basename(resolved))
        if real != resolved and (self.owned_pattern(real, key) is None or self.excluded(real)):
            return False
        self.owned_removals.append((pattern, resolved))
        return True

    GIT_VALUE = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"}
    PUSH_VALUE = {"-o", "--push-option", "--repo", "--receive-pack", "--exec"}
    # git commit's short options that take a value: in a cluster, what follows one of them is that value.
    COMMIT_VALUE_SHORT = "mFCctSu"
    # A guard lives in the global config (hooksPath, the sops filters): these drop it for the command.
    GUARD_KEYS = re.compile(r"^(?:core\.hookspath|filter\.sops|diff\.sops)", re.I)
    # Under a reset git environment, only what never runs a filter, a textconv or a hook.
    RESET_SAFE = {"status", "rev-parse", "branch", "remote", "fetch", "ls-files", "ls-tree", "rev-list", "config",
                  "tag", "describe", "show-ref", "for-each-ref", "merge-base", "version", "help", "log"}
    PATCH_FLAGS = re.compile(r"^(?:-p|-u|-L.*|-c|--cc|--patch.*|--textconv|--word-diff.*|--full-diff|--ext-diff)$")
    GUARD_ENV = {"GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM"}
    WRITES_HISTORY = {"commit", "merge", "rebase", "cherry-pick", "am"}
    # Older briefs gave sessions a `-c core.hooksPath=… -c user.signingkey=…` recipe: the refusal names today's.
    COMMIT_RECIPE = ("commit with a plain `git commit` (the global config already signs, runs the hooks and the "
                     "sops filters); if a hook refuses, fix what it reports")

    def check_git(self, argv):
        """A guard bypass (--no-verify, commit -n, a -c or an assignment that drops the global hooks or sops
        filters); a push that forces or deletes a protected branch. A forced push with no refspec is refused
        too: its target is the upstream, which the text does not name."""
        args = argv[1:]
        if "--no-verify" in args:
            self.deny(f"git --no-verify skips the hooks that guard commits and pushes; {self.COMMIT_RECIPE}", argv)
            return
        i = skip_options(args, self.GIT_VALUE)
        for j, tok in enumerate(args[:i]):
            key = None
            if tok == "-c" and j + 1 < i:
                key = args[j + 1]
            elif tok.startswith("-c") and not tok.startswith("--"):
                key = tok[2:]
            elif tok.startswith("--config-env="):
                key = tok.split("=", 1)[1]
            if key and self.GUARD_KEYS.match(key):
                self.deny(f"git -c overrides a guard (core.hooksPath, a sops filter or textconv); {self.COMMIT_RECIPE}", argv)
                return
        sub = args[i] if i < len(args) else None
        if sub in self.WRITES_HISTORY and any(a.split("=", 1)[0] in self.GUARD_ENV for a in self.assignments):
            self.deny(f"git {sub} without the global config drops its hooks and sops filters; {self.COMMIT_RECIPE}", argv)
            return
        if (self.git_env_reset or self.git_env_tainted) and (
                sub not in self.RESET_SAFE or sub == "log" and any(self.PATCH_FLAGS.match(a) for a in args[i + 1:])):
            self.deny(f"git {sub} under a reset or rewritten git environment, where the sops filters and textconv are no "
                      "longer neutral (env -i/-u, sudo, a GIT_CONFIG* assignment); run it in the session's own environment",
                      argv)
            return
        if sub == "commit":
            for tok in args[i + 1:]:
                if tok == "--":
                    break
                if tok.startswith("-") and not tok.startswith("--"):
                    for ch in tok[1:]:
                        if ch == "n":
                            self.deny(f"git commit -n is --no-verify; {self.COMMIT_RECIPE}", argv)
                            return
                        if ch in self.COMMIT_VALUE_SHORT:
                            break
            return
        if sub != "push":
            return
        push = args[i + 1:]
        refs = positionals(push, self.PUSH_VALUE)[1:]
        force = any(t in ("--force", "--force-with-lease") or t.startswith("--force-with-lease=")
                    or (t.startswith("-") and not t.startswith("--") and "f" in t[1:]) for t in push)
        force = force or any(r.startswith("+") for r in refs)
        delete = "--delete" in push or any(t.startswith("-") and not t.startswith("--") and "d" in t[1:] for t in push)
        protected = self.table.get("protected_branches", [])

        def target(ref):
            return ref.lstrip("+").rsplit(":", 1)[-1].removeprefix("refs/heads/")

        if force and (not refs or any(target(r) in protected for r in refs)):
            self.deny(f"forced push to {'/'.join(protected)}, or with no refspec, rewrites public history", argv)
        elif any(r.startswith(":") and target(r) in protected for r in refs) or \
                (delete and any(target(r) in protected for r in refs)):
            self.deny(f"deletes a remote {'/'.join(protected)}", argv)

    COPY_TO_HOSTS = ("ssh://", "ssh-ng://")

    def check_nix_copy(self, argv):
        """A --to a binary cache publishes; a --to a fleet machine over ssh only feeds it. Anything that is
        not an ssh store, a bare path included, is taken for a cache."""
        args = argv[1:]
        for i, tok in enumerate(args):
            if tok == "--to":
                dest = args[i + 1] if i + 1 < len(args) else ""
            elif tok.startswith("--to="):
                dest = tok.split("=", 1)[1]
            else:
                continue
            if not dest.startswith(self.COPY_TO_HOSTS):
                self.deny("nix copy --to a binary cache publishes; publication is the publishing user's job", argv)
                return

    def check(self, argv):
        prog, args = argv[0], argv[1:]
        if prog in ("export", "declare", "typeset", "local", "readonly", "unset"):
            for tok in args:
                self.note_env(tok)
        spec = self.table.get("vz_recover")
        if spec:
            if any(self.names_vz_recover(a) for a in self.assignments):
                self.deny(f"an assignment naming vz-recover: {spec['why']}", argv)
                return
            if prog in spec["other_programs"] and any(self.names_vz_recover(a) for a in args):
                self.deny(f"{prog} toward vz-recover: {spec['why']}", argv)
                return
            # git reaches a host through a remote url or its own ssh command; a message that names the host is not a call.
            if prog == "git" and any(re.search(r"(?i)(^|[@/])vzrecover\.[^\s/]*:|ssh://[^\s]*vzrecover", a)
                                     or (re.match(r"(?i)core\.sshcommand=", a) and self.names_vz_recover(a))
                                     for a in args):
                self.deny(f"git toward vz-recover: {spec['why']}", argv)
                return
        if prog == "find":
            for k, a in enumerate(args):
                if a in ("-exec", "-execdir", "-ok", "-okdir"):
                    end = next((j for j in range(k + 1, len(args)) if args[j] in (";", "+")), len(args))
                    if args[k + 1:end]:
                        self.analyze(" ".join(shlex.quote(x) for x in args[k + 1:end]), 1)
        if prog == "find" and self.find_removes(args):
            why = self.find_removal(args)
            if why:
                self.deny(why, argv)
                return
        if prog in ("rm", "rmdir"):
            flags = [t for t in args if t.startswith("-")]
            targets = [t for t in args if not t.startswith("-")]
            if self.cwd_lost and any(not t.startswith(("/", "~")) and not re.match(r"^\$(?:HOME|\{HOME\})(?:/|$)", t)
                                     for t in targets):
                self.deny("a relative removal after a cd whose target the hook cannot resolve; name the absolute path", argv)
                return
            if any(t.startswith("~") and self.resolve(t) is None for t in targets):
                self.deny("a ~user path the hook cannot resolve; name the absolute path", argv)
                return
            for t in targets:
                why = self.foreign(self.resolve(t)) if self.resolve(t) else None
                if why:
                    self.deny(f"{why}; ask its owner", argv)
                    return
            plain = all(re.fullmatch(r"-[rRfdv]+|--recursive|--force|--dir|--verbose", f) for f in flags)
            if len(targets) == 1 and plain and self.owned_removal("owned", argv):
                return
            # An rm that does not qualify voids the grant for the whole call.
            self.other_commands += 1
        elif prog == "git" and self.owned_worktree(argv):
            return
        elif prog not in self.NEUTRAL:
            self.other_commands += 1
        self.check_rest(argv)

    # Commands that neither write nor run anything else: they may stand beside an owned removal (security, 2026-10-17).
    NEUTRAL = {"cd", "pushd", "echo", "printf", "ls", "test", "[", "true", "stat"}

    FIND_REMOVERS = {"rm", "rmdir", "unlink", "shred", "mv"} | SHELLS

    @staticmethod
    def find_removes(args):
        """Whether find deletes what it finds: -delete, or a remover or a shell run by -exec, -execdir, -ok or -okdir
        (a shell's script is not seen, so it is taken for a remover)."""
        return any(a == "-delete" or (a in ("-exec", "-execdir", "-ok", "-okdir") and i + 1 < len(args)
                                      and os.path.basename(args[i + 1]) in Analyzer.FIND_REMOVERS)
                   for i, a in enumerate(args))

    def find_removal(self, args):
        """Why a deleting find is refused: a start in another session's area (or holding one), a relative start after
        a lost cwd, or a start the hook cannot resolve. None when every start may be judged by the other rules."""
        i = 0
        while i < len(args) and args[i] in ("-H", "-L", "-P", "-E", "-X", "-d", "-s", "-x"):
            i += 1
        starts = []
        while i < len(args) and not args[i].startswith("-") and args[i] not in ("(", "!", ")"):
            starts.append(args[i])
            i += 1
        for start in starts or ["."]:
            if self.cwd_lost and not start.startswith(("/", "~")):
                return "a deleting find from a relative start after a cd the hook cannot resolve; name the absolute path"
            path = self.resolve(start)
            if path is None:
                return f"a deleting find from {start}, which the hook cannot resolve; name the absolute path"
            why = self.foreign(path) or self.holds_foreign(path)
            if why:
                return f"a deleting find from {start}: {why}; ask its owner"
        return None

    def owned_worktree(self, argv):
        """`git [-C …] worktree remove <one exact path>`, no --force, a worktree of the calling session."""
        args = argv[1:]
        i = skip_options(args, self.GIT_VALUE)
        rest = args[i:]
        if rest[:2] != ["worktree", "remove"]:
            return False
        tail = rest[2:]
        if len(tail) != 1 or tail[0].startswith("-"):
            return False
        return self.owned_removal("worktrees", argv)

    def check_rest(self, argv):
        prog, args = argv[0], argv[1:]
        # By its base name, so a store path and `nix run …#<tool>` (unwrapped to the attribute) count too.
        tools = self.table.get("operator_tools", {})
        if prog in tools.get("programs", []) and args not in tools.get("session_forms", {}).get(prog, []):
            self.deny(f"{prog} {tools['why']}", argv)
            return
        if prog == "ndh-ops" and args[:1] == ["arm"]:
            self.deny("ndh-ops arm is the operator's: a session never arms its own delegation", argv)
            return
        if prog in ("cd", "pushd", "popd"):
            # The simple commands come in order, so a chain of cd is followed: `cd …/keyhole.d && cd keyring`.
            # A target the hook cannot resolve (a variable, a substitution, `cd -`, popd's stack) loses the cwd: a
            # relative path after it could be anywhere, so it is never judged against the previous one.
            words = [t for t in args if not t.startswith("-") or re.fullmatch(r"-[0-9]+", t)]
            stack = prog == "popd" or "-" in args or (prog == "pushd" and (not words or re.fullmatch(r"[+-][0-9]+", words[0])))
            target = "-" if stack else (words[0] if words else "~")
            # CDPATH sends a relative name elsewhere; a bare cd goes to $HOME, which then is the assigned one.
            relative = not target.startswith(("/", "~", "$"))
            moved = self.move_cwd(None if target == "-" or (self.cdpath_set and relative) else target)
            if self.is_protected(moved):
                self.deny("enters the operator's secret material", argv)
            return
        if any(self.reaches_protected(t) for t in args):
            self.deny("names the operator's secret material", argv)
            return
        if prog in self.TREE_READERS:
            why = self.walks_into_protected(prog, args)
            if why:
                self.deny(why, argv)
                return
        for store in self.table.get("store_rules", []):
            if prog != store["program"]:
                continue
            verb = next((t for t in args if not t.startswith("-")), None)
            if verb in store["free_verbs"]:
                return
            if verb in store["decrypts_all"]:
                self.deny(f"{prog} {verb} decrypts the whole store, {store['prefix']}/ included", argv)
                return
            names = (os.path.normpath(t.split("=", 1)[1] if t.startswith("-") and "=" in t else t).lstrip("/")
                     for t in args)
            if any(n == store["prefix"] or n.startswith(store["prefix"] + "/") for n in names):
                self.deny(f"{prog} reaches the {store['prefix']}/ entries", argv)
            return
        for rule in self.table.get("option_rules", []):
            if prog not in rule["programs"]:
                continue
            forbidden, command = self.option_hits(args, rule)
            if forbidden:
                self.deny(f"{prog} {forbidden} {rule['why']}", argv)
            elif rule["default_decrypts"] and not command:
                self.deny(f"{prog} with no command runs its default operation, which decrypts its input", argv)
            return
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
            if any(a == f or a.startswith(f + "=") for a in args for f in spec.get("flag_verbs", [])):
                self.deny(f"mutating {prog} flag", argv)
            return
        if prog == "git":
            self.check_git(argv)
            return
        if prog == "nix":
            self.check_nix_copy(argv)
            return
        for launcher in self.table.get("ask_launchers", []):
            if prog != launcher["program"]:
                continue
            joined = " ".join(args)
            if all(s in joined for s in launcher.get("all_args_contain", [])) and \
                    any(s in joined for s in launcher.get("any_arg_contains", [""])):
                self.ask("seed run whose live/preview mode is decided inside the JVM, not in this text", argv)


def audit(line):
    """The allowed removals, one line each, in the operator's state dir; a failed write never blocks."""
    try:
        state = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "claude-deny-hook")
        os.makedirs(state, exist_ok=True)
        with open(os.path.join(state, "log"), "a", encoding="utf-8") as fh:
            fh.write(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {line}\n")
    except OSError:
        pass


def main():
    try:
        event = json.load(sys.stdin)
        if event.get("tool_name") != "Bash":
            return 0
        command = event.get("tool_input", {}).get("command")
        if not isinstance(command, str):
            raise Refused("no command text to inspect")
        analyzer = Analyzer(load_table(), event.get("cwd") or "", os.environ.get("HOME") or os.path.expanduser("~"),
                            load_owned(), event.get("session_id") or "")
        # The keyring material, a first line: by its text anywhere (a quoted path, a -c script) and by the
        # session's own cwd. A path built at run time (a variable, a computed cd) escapes the text.
        if analyzer.is_protected(os.path.normpath(analyzer.cwd) if analyzer.cwd else None):
            analyzer.deny("runs inside the operator's secret material", [command])
        for p in analyzer.protected:
            for s in spellings(p, analyzer.home):
                if re.search(re.escape(s) + r"(?=$|[/\s'\";&|)<>])", command):
                    analyzer.deny("names the operator's secret material", [s])
        for rule in analyzer.table.get("text_rules", []):
            if re.search(rule["pattern"], command):
                analyzer.deny("names the operator's secret material", [rule["why"]])
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
    if not asks and analyzer.owned_removals and not analyzer.other_commands:
        # A call made only of the session's own removals (and cd): no prompt, and an audit line.
        reason = "; ".join(f"{analyzer.session} {analyzer.session_id} removes {path} ({pattern})"
                           for pattern, path in analyzer.owned_removals)
        audit(reason)
        json.dump({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow",
                                          "permissionDecisionReason": "owned area: " + reason}}, sys.stdout)
        return 0
    if asks:
        json.dump({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask",
                                          "permissionDecisionReason": "; ".join(asks)}}, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
