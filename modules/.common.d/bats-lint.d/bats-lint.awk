# bats-lint — a test line that checks nothing.
#
# bats runs a test's body under `set -e`, but bash does not exit on a failure that is not the last command of a list
# or of a negation: mid-test, `[ "$status" -eq 3 ] && [[ … ]]` passes whatever the status, and `! grep …` passes
# whatever grep finds. Only the last command of a test checks such a line. This refuses those forms anywhere else in
# a test's body: split the list into one check per line, and write a negation `! cmd || false`.
#
# Usage: awk -f bats-lint.awk <file.bats>… — exit 0 when every file is clean, 1 when one carries a weak line.

function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

function weak(c,    i) {
  # `run cmd; check` on one line: the check is what is judged.
  if (c ~ /^run[ \t]/ && (i = index(c, ";")) > 0) c = trim(substr(c, i + 1))
  if (c ~ /^![ \t]/ && c !~ /\|\|[ \t]*false$/) return 1
  if (c ~ /^\[\[?[ \t].*\]\]?[ \t]*&&[ \t]/ && c !~ /&&[ \t]*(continue|break)([ \t;]|$)/) return 1
  return 0
}

function judge(    k) {
  # The last command checks; every one before it must check on its own.
  for (k = 1; k < count; k++)
    if (weak(cmd[k])) { printf "%s:%d: checks nothing mid-test: %s\n", file, line[k], cmd[k]; bad = 1 }
}

FNR == 1 { if (inside) judge(); inside = 0; file = FILENAME }

# A one-line test `@test "…" { … }` has a single command, which is its last.
/^@test[ \t]/ && $0 !~ /\}[ \t]*$/ { inside = 1; count = 0; next }

inside && /^\}[ \t]*$/ { judge(); inside = 0; next }

inside {
  s = trim($0)
  if (s != "" && s !~ /^#/) { count++; cmd[count] = s; line[count] = FNR }
}

END { if (inside) judge(); exit bad }
