"""secret-xtrace-guard: no secret VALUE reaches a trace or an argv, in the scripts ndh runs.

Reads each script's bash AST (`shfmt --to-json`) and follows the DATA: a variable assigned from a secret source is
tracked, and so is any variable assigned from an expansion of a tracked one. It then reports every place a tracked
value would be printed or exposed. What it measures it was measured against (bash 5.3):

- xtrace prints every command after expansion, an assignment included (`t=…`, `export E=…`, `local l=…`, a command's
  prefix `K=… cmd`), and a `[[ … ]]` test; it does NOT print a here-string's word nor a heredoc's body.
- an external command's argv is visible to `ps`; a builtin's arguments are not, and neither is the environment.

Classes (one finding per line):
  unwindowed     a tracked value expanded in a traced position outside ndh::secret:begin/end   (strict)
  argv-exposure  a tracked value in an external command's argv, window or not                 (report)
  unbalanced     begin/end that do not pair up along a block                                  (strict)
  xtrace-in-window  `set -x` (or -o xtrace) between begin and end                             (strict)
  undecidable    a construct the check cannot follow (eval, indirect expansion, a tracked value
                 passed to a function, an unknown node): red with its reason                   (strict)
  trampoline-pending  a secret-handling script not yet on the trampoline (batch 2)            (report)
  guard-before-flip   a whole-script guard under the trampoline: safe while the logger traces only
                      on request, not after batch 1's flip                                   (report)
  guard-without-bash-env  a whole-script guard that leaves BASH_ENV, so a child bash is traced (report)
  masked         a value built by replacing every occurrence of a secret: for review           (report)
  reviewed-hop   a tracked value passed to a function a reviewer followed and found safe (the
                 manifest's "reviewed" list, one reason each)                                  (report)

Usage: check.py <manifest.json>; the manifest lists {"path", "ast", "trampoline", "exempt"} per script and the
`ast` is shfmt's JSON for it. Exit 1 when a STRICT class has a finding, after printing every finding.
"""

import json
import re
import sys

STRICT = {"unwindowed", "unbalanced", "xtrace-in-window", "undecidable"}

# A command substitution reads a secret when its first command is one of these (with the operands that matter).
SECRET_READERS = [
    (re.compile(r"^sops$"), lambda a: any(x in a for x in ("-d", "--decrypt", "decrypt", "exec-env", "exec-file"))),
    (re.compile(r"^age$"), lambda a: any(x in a for x in ("-d", "--decrypt"))),
    (re.compile(r"^gpg2?$"), lambda a: any(x in a for x in ("-d", "--decrypt", "--export-secret-keys"))),
    (re.compile(r"^pass$"), lambda a: bool(a) and a[0] in ("show", "otp")),
    (re.compile(r"(^|/)atticd?-atticadm$|^atticadm$"), lambda a: "make-token" in a),
    (re.compile(r"(^|/)headscale$|^hs::headscale$"), lambda a: "preauthkeys" in a),
    (re.compile(r"(^|/)incus$|^@incusBin@$|^\$\{?incus_bin\}?$"),
     lambda a: ("trust" in a and "add" in a) or ("cluster" in a and "add" in a)),
    (re.compile(r"^remote$"), lambda a: "incus" in a and "add" in a),
    (re.compile(r"^ssh$"), lambda a: "trust" in a and "add" in a),
    (re.compile(r"^sops::edit::get_string$"), lambda a: True),
]
# A file read is a secret read when the path names a secret.
SECRET_PATH = re.compile(r"(?i)(token|secret|passphrase|password|api[._-]?key|\.sec\b|private|/run/secrets)")
# A variable whose name says it holds a secret, judged on its WORDS (split on _ and on case: API_TOKEN, apiKey,
# secret_key → api token / api key / secret key), so `sk` never matches `task`. Not when its last word says it is a
# path or a name of one (…_FILE, …_DIR, …_NAME), nor a fingerprint. Over-detects on purpose: PUBLIC_KEY matches
# (its `key` word), harmless — a public in a window costs a trace line.
SECRET_WORDS = {
    "token", "tokens", "keys", "secret", "secrets", "passphrase", "password", "passwd", "pw", "pass", "bearer", "credential",
    "credentials", "key", "apikey", "auth", "jwt", "cookie", "session", "identity", "priv", "private", "sk", "otp",
    "pin", "signing", "keyfile",
}
# The last word says what the variable holds when it is not the secret itself: a path, a name, a type, a slot id, a
# fingerprint or a digest of a key, a listing of key NAMES.
NOT_A_VALUE = {
    "file", "path", "dir", "name", "names", "index", "kind", "id", "fpr", "fingerprint", "fp", "sum", "count", "len",
    "list", "type", "slot", "yaml", "json",
}
# Commands that make a value out of nothing secret: a path, a date, a number. A secret-named variable filled by
# them alone is no secret (`tmp_keys=$(mktemp -d)`, `OBS_SESSION="$(date …)-$$-…"`).
GENERATORS = {"mktemp", "date", "hostname", "id", "uname", "basename", "dirname", "pwd", "realpath", "seq", "wc"}


def secret_name(name):
    words = [w.lower() for w in re.findall(r"[A-Z]?[a-z0-9]+|[A-Z]+(?![a-z])", name or "")]
    if not words or words[-1] in NOT_A_VALUE:
        return False
    # keyfile is a word here: the variable holds the key file's CONTENT when filled by a command.
    return any(w in SECRET_WORDS for w in words)
# A command that reads only a public's file (an ssh .pub, a certificate, an armored public export).
PUBLIC_FILE = re.compile(r'\.(pub|crt|pem\.pub|asc)\b(?!\.)')
# Builtins whose arguments no `ps` shows. Anything else (and anything shadowed) is external.
BUILTINS = {
    "printf", "echo", "read", "[", "test", "[[", "local", "declare", "typeset", "export", "readonly", "unset",
    "set", "shift", "return", "exit", "true", "false", ":", "cd", "pushd", "popd", "trap", "wait", "mapfile",
    "readarray", "printf", "let", "break", "continue", "source", ".", "type", "hash", "getopts", "shopt", "umask",
}
UNDECIDABLE_CMDS = {"eval", "command", "builtin", "enable", "env", "exec"}
WINDOW_BEGIN, WINDOW_END = "ndh::secret:begin", "ndh::secret:end"
HERE_OPS = {71, 72, 73}  # <<, <<-, <<<: bodies and words xtrace does not print
KNOWN = {
    "File", "CallExpr", "Lit", "DblQuoted", "SglQuoted", "ParamExp", "CmdSubst", "Word", "TestClause", "BinaryTest",
    "UnaryTest", "ArithmCmd", "ArithmExp", "BinaryArithm", "UnaryArithm", "BinaryCmd", "Block", "Subshell",
    "IfClause", "WhileClause", "ForClause", "WordIter", "CStyleLoop", "CaseClause", "FuncDecl", "DeclClause",
    "TimeClause", "ProcSubst", "ParenTest", "ParenArithm", "ExtGlob", "BraceExp", "LetClause", "CoprocClause",
}


class Checker:
    def __init__(self, path):
        self.path = path
        self.tracked = set()
        self.masked = set()
        self.seen = set()
        self.secret_handling = False
        self.here_redirs = []
        self.stdin_redirected = 0
        self.reviewed = set()
        self.findings = []
        self.window = 0
        self.base = 0  # 1 under the whole-script guard: every body starts inside it
        self.functions = set()

    def find(self, cls, line, why):
        self.findings.append((cls, self.path, line, why))

    # --- words -------------------------------------------------------------------------------------------------
    def lits(self, word):
        """The literal text of a word, or None when it holds an expansion."""
        out = []
        for p in (word or {}).get("Parts") or []:
            t = p.get("Type")
            if t in ("Lit", "SglQuoted"):
                out.append(p.get("Value", ""))  # an empty '' carries no Value
            elif t == "DblQuoted" and all(q.get("Type") == "Lit" for q in p.get("Parts") or []):
                out.append("".join(q.get("Value", "") for q in p.get("Parts") or []))
            else:
                return None
        return "".join(out)

    def expanded(self, node, line):
        """The tracked variables a word or node expands, at any depth, except inside a substitution: the commands
        there are judged as commands of their own (grep -f <(printf '%s' "$k") hands grep a pipe, not the key)."""
        names = set()
        def walk(n):
            if isinstance(n, dict):
                t = n.get("Type")
                if t in ("ProcSubst", "CmdSubst"):
                    self.stmts_nested(n.get("Stmts"))
                    return
                if t is not None and t not in KNOWN:
                    self.find("undecidable", line, f"unknown construct {t}")
                if t == "ParamExp":
                    # ${!arr[@]} lists an array's KEYS; any other ${!x} expands the variable x names: undecidable.
                    if n.get("Excl") and not (n.get("Index") or n.get("Names")):
                        self.find("undecidable", line, "indirect expansion ${!…}")
                    name = (n.get("Param") or {}).get("Value")
                    # ${#v} expands to a length, never the value.
                    if name in self.tracked and not n.get("Length"):
                        names.add(name)
                for k, v in n.items():
                    if k not in ("Pos", "End"):
                        walk(v)
            elif isinstance(n, list):
                for v in n:
                    walk(v)
        walk(node)
        return names

    def source_of(self, word, line):
        """Whether a word's value comes from a secret source: a command substitution that reads one ANYWHERE inside
        it (a pipeline, a process substitution feeding it, a nested substitution), or $(<secret)."""
        hit = False
        def walk(n):
            nonlocal hit
            if isinstance(n, dict):
                if n.get("Type") == "CmdSubst":
                    # Judged on its top statements: a pipeline as a whole (it may end in a public), each command
                    # of it, and what a process substitution feeds it (reads_secret walks those too).
                    if any(self.reads_secret(st, line) for st in n.get("Stmts") or []):
                        hit = True
                    return
                for k, v in n.items():
                    if k not in ("Pos", "End"):
                        walk(v)
            elif isinstance(n, list):
                for v in n:
                    walk(v)
        walk(word)
        return hit

    def fed(self, value):
        """The tracked variables a value's substitutions expand anywhere inside, unless they end in a public:
        `t="$(printf %s "$k" | cut -c1-8)"` holds part of k, so t is tracked (rule 1, data, not names)."""
        names = set()
        def walk(n):
            if isinstance(n, dict):
                if n.get("Type") in ("ProcSubst", "CmdSubst"):
                    if not any(self.derives_public(st) for st in n.get("Stmts") or []):
                        text = json.dumps(n.get("Stmts"))
                        names.update(v for v in self.tracked if f'"Value": "{v}"' in text)
                    return
                for k, v in n.items():
                    if k not in ("Pos", "End"):
                        walk(v)
            elif isinstance(n, list):
                for v in n:
                    walk(v)
        walk(value)
        return names - self.masked

    def only_generators(self, value):
        """Every command substitution in the value runs only GENERATORS (mktemp, date…): nothing secret goes in."""
        subs = self.substitutions(value)
        def gen(st):
            cmd = st.get("Cmd") or {}
            if cmd.get("Type") == "BinaryCmd":
                return gen(cmd["X"]) and gen(cmd["Y"])
            if cmd.get("Type") != "CallExpr" or not cmd.get("Args"):
                return False
            return (self.lits(cmd["Args"][0]) or "").rsplit("/", 1)[-1] in GENERATORS
        return bool(subs) and all(all(gen(st) for st in s.get("Stmts") or []) for s in subs)

    def has_cmdsubst(self, word):
        return '"CmdSubst"' in json.dumps(word)

    def substitutions(self, node):
        """The process and command substitutions in a node, outermost only."""
        out = []
        def walk(n):
            if isinstance(n, dict):
                if n.get("Type") in ("ProcSubst", "CmdSubst"):
                    out.append(n)
                    return
                for k, v in n.items():
                    if k not in ("Pos", "End"):
                        walk(v)
            elif isinstance(n, list):
                for v in n:
                    walk(v)
        walk(node)
        return out

    def derives_public(self, stmt):
        """Whether a pipeline's LAST command derives a public from what it reads (age-keygen -y, ssh-keygen -y, a
        --public flag): its output is the public, whatever secret went in."""
        cmd = stmt.get("Cmd") or {}
        if cmd.get("Type") == "BinaryCmd":
            return self.derives_public(cmd["Y"])
        if cmd.get("Type") != "CallExpr" or not cmd.get("Args"):
            return False
        words = [self.lits(a) or "" for a in cmd["Args"]]
        name = words[0].rsplit("/", 1)[-1]
        return (name in ("age-keygen", "ssh-keygen") and "-y" in words) or "--public" in words

    def reads_stdin(self, stmt):
        """Whether a statement reads its stdin: cat/head/tail/tr with no file operand, $(</dev/stdin), or the
        first command of a pipeline doing so."""
        cmd = stmt.get("Cmd") or {}
        if cmd.get("Type") == "BinaryCmd":
            return self.reads_stdin(cmd["X"])
        redirs = stmt.get("Redirs") or []
        if any(r.get("Op") == 65 and (self.lits(r.get("Word")) or "") in ("/dev/stdin", "/dev/fd/0") for r in redirs):
            return True
        if any(r.get("Op") in (65, 71, 72, 73) for r in redirs):
            return False  # its stdin is a file or a here-doc of this script: judged as such elsewhere
        if cmd.get("Type") != "CallExpr" or not cmd.get("Args"):
            return False
        words = [self.lits(a) for a in cmd["Args"]]
        name = (words[0] or "").rsplit("/", 1)[-1]
        if name == "tr":
            return True  # tr never takes a file
        operands, i = [], 1
        while i < len(words):
            w = words[i]
            if w is not None and w in ("-c", "-n") and name in ("head", "tail"):
                i += 2  # head -c 64, tail -n 1: the number is no file
                continue
            if w is None or not w.startswith("-") or w == "-":
                operands.append(w)
            i += 1
        return name in ("cat", "head", "tail") and (not operands or operands == ["-"])

    def stdin_source(self, value):
        """A value filled by a command substitution that reads stdin (`value="$(cat)"`)."""
        def walk(n):
            if isinstance(n, dict):
                if n.get("Type") == "CmdSubst":
                    return any(self.reads_stdin(st) for st in n.get("Stmts") or [])
                return any(walk(v) for k, v in n.items() if k not in ("Pos", "End"))
            if isinstance(n, list):
                return any(walk(v) for v in n)
            return False
        return walk(value)

    def reads_secret(self, stmt, line):
        cmd = stmt.get("Cmd") or {}
        t = cmd.get("Type")
        if t == "BinaryCmd":  # a pipeline reads a secret when any of its commands does, unless it ends in a public
            if self.derives_public(stmt):
                return False
            return self.reads_secret(cmd["X"], line) or self.reads_secret(cmd["Y"], line)
        for r in stmt.get("Redirs") or []:
            if r.get("Op") == 65 and SECRET_PATH.search(json.dumps(r.get("Word"))):
                return True
        if t != "CallExpr" or not cmd.get("Args"):
            return False
        # A process substitution or a nested substitution in its arguments feeds it a secret (curl reading a
        # client secret through <(sops -d …)): what it prints is then a secret too.
        for sub in self.substitutions(cmd["Args"][1:]):
            if any(self.reads_secret(st, line) for st in sub.get("Stmts") or []):
                return True
        name = self.lits(cmd["Args"][0]) or ""
        args = [self.lits(a) or "" for a in cmd["Args"][1:]]
        if name in ("cat", "tr", "head") and SECRET_PATH.search(json.dumps(cmd["Args"][1:] + (stmt.get("Redirs") or []))):
            return True
        return any(rx.search(name) and pred(args) for rx, pred in SECRET_READERS)

    # --- statements ----------------------------------------------------------------------------------------------
    def stmts_nested(self, stmts):
        """A substitution's statements, checked once each, in the window of the command that holds them."""
        for st in stmts or []:
            key = id(st)
            if key in self.seen:
                continue
            self.seen.add(key)
            self.stmt(st)

    def stmts(self, stmts):
        for st in stmts or []:
            self.stmt(st)

    def stmt(self, st):
        line = (st.get("Position") or {}).get("Line", 0)
        cmd = st.get("Cmd")
        traced_redirs = [r for r in st.get("Redirs") or [] if r.get("Op") not in HERE_OPS]
        here_redirs = [r for r in st.get("Redirs") or [] if r.get("Op") in HERE_OPS]
        if cmd is None:
            return
        t = cmd.get("Type")
        if t is not None and t not in KNOWN:
            self.find("undecidable", line, f"unknown construct {t}")
            return
        # A compound command whose stdin is redirected (`while read …; done < file`, `<<<"$list"`, `< <(cmd)`)
        # feeds its reads that file, not the script's own stdin.
        redirected = t != "CallExpr" and any(r.get("Op") in (65, 71, 72, 73) for r in st.get("Redirs") or [])
        self.stdin_redirected += redirected
        try:
            self.stmt_cmd(st, cmd, t, line, traced_redirs, here_redirs)
        finally:
            self.stdin_redirected -= redirected

    def stmt_cmd(self, st, cmd, t, line, traced_redirs, here_redirs):
        if t == "CallExpr":
            self.here_redirs = here_redirs
            self.call(cmd, line, traced_redirs)
        elif t == "DeclClause":
            self.decl(cmd, line)
        elif t == "BinaryCmd":
            self.stmt(cmd["X"])
            # `cmd | while read …`: the right side of a pipe reads the pipe, not the script's stdin.
            piped = cmd.get("Op") in (13, 14)  # | and |& (shfmt 3.13: && is 11, || is 12)
            self.stdin_redirected += piped
            try:
                self.stmt(cmd["Y"])
            finally:
                self.stdin_redirected -= piped
        elif t in ("Block", "Subshell"):
            self.block(cmd.get("Stmts"), line)
        elif t == "IfClause":
            self.if_clause(cmd, line)
        elif t == "WhileClause":
            self.stmts(cmd.get("Cond"))
            self.block(cmd.get("Do"), line)
        elif t == "ForClause":
            self.traced_use(cmd.get("Loop"), line)
            self.block(cmd.get("Do"), line)
        elif t == "CaseClause":
            self.traced_use(cmd.get("Word"), line)
            for item in cmd.get("Items") or []:
                self.block(item.get("Stmts"), line)
        elif t == "FuncDecl":
            name = (cmd.get("Name") or {}).get("Value")
            self.functions.add(name)
            # A function body is judged on its own windows: its callers' are not its. The whole-script guard is
            # the one exception, since it holds for the whole process.
            saved = self.window
            self.window = self.base
            self.block((cmd.get("Body") or {}).get("Cmd", {}).get("Stmts"), line)
            self.window = saved
        elif t in ("TestClause", "ArithmCmd", "LetClause"):
            self.traced_use(cmd, line)
        elif t in ("TimeClause", "CoprocClause"):
            self.find("undecidable", line, f"{t} around a command")
        # A here-string or heredoc carries a tracked value out of the trace: safe, wherever it is.

    def block(self, stmts, line):
        before = self.window
        self.stmts(stmts)
        if self.window != before:
            self.find("unbalanced", line, f"a block opens or closes {self.window - before:+d} secret window(s)")
            self.window = before

    def if_clause(self, c, line):
        self.stmts(c.get("Cond"))
        self.block(c.get("Then"), line)
        if c.get("Else"):
            e = c["Else"]
            if e.get("Cond") is not None or e.get("Then") is not None:
                self.if_clause(e, line)
            else:
                self.block(e.get("Then") or e.get("Stmts"), line)

    def traced_use(self, node, line):
        names = self.expanded(node, line)
        if names and self.window == 0:
            self.find("unwindowed", line, "traced outside a window: " + ", ".join(sorted(names)))

    def masks(self, value):
        """Whether a value is built from a replacement of every occurrence of a tracked value (${v//"$secret"/x})."""
        hit = False
        def walk(n):
            nonlocal hit
            if isinstance(n, dict):
                if n.get("Type") == "ParamExp" and (n.get("Repl") or {}).get("All"):
                    if self.expanded((n.get("Repl") or {}).get("Orig"), 0):
                        hit = True
                for k, v in n.items():
                    if k not in ("Pos", "End"):
                        walk(v)
            elif isinstance(n, list):
                for v in n:
                    walk(v)
        walk(value)
        return hit

    def assign(self, a, line):
        name = (a.get("Name") or {}).get("Value")
        value = a.get("Value") or a.get("Array")
        if value is None:
            return
        if self.masks(value):
            # The replaced value is gone from this one; what else it carries is the reviewer's call: reported.
            self.masked.add(name)
            self.tracked.discard(name)
            self.find("masked", line, f"{name} is a tracked value with every occurrence of a secret replaced: review")
            return
        # The backstop for a source the reader list does not know (an OAuth exchange, a new CLI): a variable named
        # as a secret and filled by a command is tracked. Over-detection is wanted; a false one reads as a window.
        from_secret = (
            self.source_of(value, line)
            or (
                secret_name(name)
                and self.has_cmdsubst(value)
                and not PUBLIC_FILE.search(json.dumps(value))
                and not self.only_generators(value)
            )
            # In a secret-handling script, what it reads from its stdin may be what a caller piped in (hs-lib's
            # set_string): tracked, unnamed or not. Over-detection is the side asked for.
            or (self.secret_handling and self.stdin_source(value))
        )
        names = self.expanded(value, line) | self.fed(value)
        if from_secret or names:
            self.tracked.add(name)
            if self.window == 0:
                self.find("unwindowed", line, f"{name} assigned a secret value outside a window (xtrace prints it)")
        elif name in self.tracked:
            self.tracked.discard(name)  # reassigned from a clean value: no longer a secret

    def decl(self, d, line):
        for a in d.get("Args") or []:
            self.assign(a, line)

    def call(self, c, line, traced_redirs):
        for a in c.get("Assigns") or []:
            self.assign(a, line)
        args = c.get("Args") or []
        if not args:
            return
        name = self.lits(args[0])
        if name is None:
            # A command named by a variable ($CURL, "${incus_bin}"): external, unless the name itself is a secret.
            if self.expanded(args[0], line):
                self.find("undecidable", line, "a command whose name expands a tracked value")
                return
            name = "<external>"
        rest = args[1:]
        if name == WINDOW_BEGIN:
            self.window += 1
            return
        if name == WINDOW_END:
            if self.window == 0:
                self.find("unbalanced", line, "ndh::secret:end with no open window")
            else:
                self.window -= 1
            return
        if name == "set" and self.window > 0:
            words = [self.lits(a) or "" for a in rest]
            if any(re.fullmatch(r"-[a-zA-Z]*x[a-zA-Z]*", w) for w in words) or ("-o" in words and "xtrace" in words):
                self.find("xtrace-in-window", line, "set -x inside a secret window")
        if name == "read":
            silent = any(re.fullmatch(r"-[a-zA-Z]*s[a-zA-Z]*", self.lits(a) or "") for a in rest)
            # A read from the script's own stdin (no redirect of a file or here-doc): in a secret-handling script,
            # what it reads is tracked; `read -s` is a secret anywhere.
            own_stdin = self.stdin_redirected == 0 and not any(
                r.get("Op") in (65, 71, 72, 73) for r in traced_redirs + self.here_redirs
            )
            if silent or (self.secret_handling and own_stdin):
                for v in read_targets([self.lits(a) or "" for a in rest]):
                    self.tracked.add(v)
            if silent and self.window == 0:
                self.find("unwindowed", line, "read -s outside a window")
        names = self.expanded(rest, line) | self.expanded(traced_redirs, line)
        if not names:
            return
        if name in UNDECIDABLE_CMDS:
            self.find("undecidable", line, f"a tracked value under {name}: " + ", ".join(sorted(names)))
        elif name in self.functions or "::" in name:
            # A hop a reviewer followed into the function and found safe stays in the report, never strict.
            cls = "reviewed-hop" if name in self.reviewed else "undecidable"
            self.find(cls, line, f"a tracked value passed to the function {name}: " + ", ".join(sorted(names)))
        elif name not in BUILTINS:
            self.find("argv-exposure", line, f"{name} gets " + ", ".join(sorted(names)) + " in its argv")
        if self.window == 0:
            self.find("unwindowed", line, f"{name} expands " + ", ".join(sorted(names)) + " outside a window")


def read_targets(words):
    """The variables a `read` fills: its plain words, and the array of -a. Options whose last letter takes an
    argument (-p prompt, -d delim, -n/-N count, -t timeout, -u fd, -i text, -a array) consume the next word."""
    out, i = [], 0
    while i < len(words):
        w = words[i]
        if w.startswith("-") and len(w) > 1:
            if w[-1] in "pdnNtuia":
                if w[-1] == "a" and i + 1 < len(words):
                    out.append(words[i + 1])
                i += 2
                continue
            i += 1
            continue
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", w):
            out.append(w)
        i += 1
    return out


def secret_handling(ast):
    """A script that handles a secret: it opens a window, carries the whole-script guard, or names a secret
    reader. Its stdin reads are then tracked too."""
    text = json.dumps(ast)
    return (
        f'"{WINDOW_BEGIN}"' in text
        or ('"+x"' in text and '"SHELLOPTS"' in text)
        or any(f'"Value": "{w}"' in text for w in ("sops", "age", "gpg", "pass", "atticadm", "make-token"))
    )


def whole_script_guard(ch, ast):
    """The whole-script guard, when it opens the script: `set +x` under `case $- in *x*)` and
    `export -n SHELLOPTS`, both among the first top-level statements and before any secret is read. Returns
    "ok", "no-bash-env" (BASH_ENV is not unset with it) or None."""
    head = (ast.get("Stmts") or [])[:8]
    text = json.dumps(head)
    if '"+x"' not in text or '"SHELLOPTS"' not in text or '"-n"' not in text:
        return None
    return "ok" if '"BASH_ENV"' in text else "no-bash-env"


def main(manifest):
    findings = []
    for entry in json.load(open(manifest)):
        if entry.get("exempt"):
            continue
        ch = Checker(entry["path"])
        ch.reviewed = set(entry.get("reviewed") or [])
        ast = json.load(open(entry["ast"]))
        if "ParseError" in ast:
            # What the check cannot read, it cannot clear; a reviewed exemption names what shfmt cannot parse.
            findings.append(("undecidable", entry["path"], 0, "shfmt cannot parse it: " + ast["ParseError"]))
            continue
        ch.secret_handling = secret_handling(ast)
        guarded = whole_script_guard(ch, ast)
        if guarded:
            # The whole script is one window (the guard of the scripts that handle privates throughout, until
            # batch 1 turns them into local windows).
            ch.window = ch.base = 1
            if guarded == "no-bash-env":
                ch.find("guard-without-bash-env", 0, "whole-script guard leaves BASH_ENV: a child bash can be traced")
            if entry.get("trampoline"):
                # It holds because it unsets NDH_LOGGER_XTRACE, so the logger never turns xtrace on: once batch 1
                # makes xtrace the logger's default, the guard no longer reaches the logged command.
                ch.find("guard-before-flip", 0, "whole-script guard under the trampoline: local windows before batch 1's flip")
        # Functions are declared before they are called, wherever they sit: collect their names first.
        for st in ast.get("Stmts") or []:
            if (st.get("Cmd") or {}).get("Type") == "FuncDecl":
                ch.functions.add(st["Cmd"]["Name"]["Value"])
        ch.stmts(ast.get("Stmts"))
        if ch.window != (1 if guarded else 0):
            ch.find("unbalanced", 0, f"the script ends inside {ch.window - (1 if guarded else 0)} secret window(s)")
        if ch.tracked and not entry.get("trampoline"):
            ch.find("trampoline-pending", 0, "handles a secret and is not on the trampoline yet (batch 2)")
        findings += ch.findings
    for cls, path, line, why in sorted(findings, key=lambda f: (f[0] not in STRICT, f[1], f[2])):
        print(f"{cls}\t{path}:{line}\t{why}")
    return 1 if any(f[0] in STRICT for f in findings) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
