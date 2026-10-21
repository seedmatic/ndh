#!/usr/bin/env bats
# secret-xtrace-guard's mutants: one small script per rule, each must land in the class it names; and the
# clean forms beside them must not. The checker is the real one, the ASTs come from the real shfmt.

setup() {
  T=$BATS_TEST_TMPDIR
  CHECK=$BATS_TEST_DIRNAME/../check.py
}

# check <class|clean> <script text>: the script, checked alone; "clean" asserts no finding at all.
check() {
  local want=$1 text=$2
  printf '%s\n' "$text" >"$T/s.sh"
  shfmt --to-json <"$T/s.sh" >"$T/s.json"
  printf '[{"path": "s.sh", "ast": "%s", "trampoline": true}]' "$T/s.json" >"$T/m.json"
  run python3 -I "$CHECK" "$T/m.json"
  if [ "$want" = clean ]; then
    [ -z "$output" ] || { echo "expected no finding, got: $output" >&2; return 1; }
    [ "$status" -eq 0 ]
  else
    [[ $output == *"$want"$'\t'* ]] || { echo "expected $want, got: $output" >&2; return 1; }
  fi
}

@test "a secret read outside a window is red; inside one it is clean" {
  check unwindowed 't="$(sops -d f)"'
  check clean $'ndh::secret:begin "w"\nt="$(sops -d f)"\nt=""\nndh::secret:end'
}

@test "the window removed: a use after end is red" {
  check unwindowed $'ndh::secret:begin "w"\nt="$(sops -d f)"\nndh::secret:end\nprintf %s "$t" >f'
}

@test "rule 1, data not names: a copy, a substring, a substitution built from it are tracked" {
  check unwindowed $'ndh::secret:begin "w"\nt="$(sops -d f)"\nndh::secret:end\nb=$t'
  check unwindowed $'ndh::secret:begin "w"\nt="$(sops -d f)"\nndh::secret:end\nb=${t:0:4}'
  check unwindowed $'ndh::secret:begin "w"\nt="$(sops -d f)"\nndh::secret:end\nb="$(printf %s "$t" | cut -c1-8)"'
}

@test "rule 1: a pipeline that ends in a public is no secret; one that ends elsewhere is" {
  check clean 'p="$(pass show e | age-keygen -y)"'
  check unwindowed 'p="$(pass show e | cat)"'
}

@test "rule 1: a source behind a process substitution, and a secret-named variable from a command" {
  check unwindowed 'T="$(curl --data-urlencode s@<(sops -d f) u | yq .t)"'
  check unwindowed 'API_TOKEN="$(curl -fsS u)"'
  check clean 'key="$(cut -d" " -f1,2 a.pub)"'
}

@test "rule 2: a tracked value passed to a function is undecidable" {
  check undecidable $'f() { :; }\nndh::secret:begin "w"\nt="$(sops -d f)"\nf "$t"\nndh::secret:end'
}

@test "rule 2: a function body is judged on its own windows, not its callers'" {
  check unwindowed $'g() { t="$(sops -d f)"; }\nndh::secret:begin "w"\ng\nndh::secret:end'
}

@test "rule 3: set -x inside a window is red" {
  check xtrace-in-window $'ndh::secret:begin "w"\nset -x\nndh::secret:end'
}

@test "rule 4: an unbalanced window, at the end of a script or of a block, is red" {
  check unbalanced 'ndh::secret:begin "w"'
  check unbalanced 'ndh::secret:end'
  check unbalanced $'if x; then\n  ndh::secret:begin "w"\nfi'
}

@test "rule 5: a tracked value in an external argv is argv-exposure; through a builtin, a pipe or stdin it is not" {
  check argv-exposure $'ndh::secret:begin "w"\nt="$(sops -d f)"\ncurl -H "$t" u\nndh::secret:end'
  check clean $'ndh::secret:begin "w"\nt="$(sops -d f)"\nprintf %s "$t" >f\nt=""\nndh::secret:end'
  check clean $'ndh::secret:begin "w"\nt="$(sops -d f)"\nndh::secret:end\nyq .x - <<<"$t"'
  # A pipe is no argv; the printf feeding it is still traced, so it sits in the window.
  check clean $'ndh::secret:begin "w"\nt="$(sops -d f)"\ngrep -qF -f <(printf "%s\\n" "$t") f\nt=""\nndh::secret:end'
  check unwindowed $'ndh::secret:begin "w"\nt="$(sops -d f)"\nndh::secret:end\ngrep -qF -f <(printf "%s\\n" "$t") f'
}

@test "rule 5: a tracked value under eval, env, command or exec is undecidable" {
  check undecidable $'ndh::secret:begin "w"\nt="$(sops -d f)"\nenv K="$t" yq .x\nndh::secret:end'
  check undecidable $'ndh::secret:begin "w"\nt="$(sops -d f)"\neval "x=$t"\nndh::secret:end'
}

@test "read -s outside a window is red; an indirect expansion is undecidable; array keys are not" {
  check unwindowed 'read -r -s p <f'
  check undecidable 'x=${!y}'
  check clean $'for i in "${!a[@]}"; do :; done'
}

@test "a masking substitution is reported for review, and what it builds is no longer tracked" {
  check masked $'ndh::secret:begin "w"\nt="$(sops -d f)"\nl=${o//"$t"/x}\nt=""\nndh::secret:end\nprintf %s "$l" >&2'
}

@test "the whole-script guard covers the script; under the trampoline it is flagged for batch 1" {
  check guard-before-flip $'case $- in *x*) { set +x; } 2>/dev/null ;; esac\nexport -n SHELLOPTS\nunset BASH_ENV\nt="$(sops -d f)"'
  check guard-without-bash-env $'case $- in *x*) { set +x; } 2>/dev/null ;; esac\nexport -n SHELLOPTS\nt="$(sops -d f)"'
}

@test "what shfmt cannot parse is undecidable, never cleared" {
  printf '[{"path": "s.sh", "ast": "%s", "trampoline": false}]' "$T/bad.json" >"$T/m.json"
  printf '{"ParseError": "1:1: nope"}' >"$T/bad.json"
  run python3 -I "$CHECK" "$T/m.json"
  [ "$status" -eq 1 ]
  [[ $output == *"undecidable"* ]]
}
