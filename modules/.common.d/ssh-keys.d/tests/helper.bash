# Render a @placeholder@ script and source it, so its functions can be tested.
#
# The scripts under ssh-keys.d/ are rendered by pkgs.replaceVars at build time and
# are therefore NOT sourceable from the worktree: `source @nixBashTrampoline@` is a
# literal placeholder until Nix substitutes it. That is the single reason these
# functions had no tests. Rendering the two placeholders here is the whole harness.

# Locate the trampoline the scripts source. Fails loudly rather than stubbing: a
# stub would let a test pass against a logger API the real script does not have.
ndh_trampoline() {
  local t
  t="$(find /nix/store -maxdepth 2 -name nix-bash-trampoline.sh -path '*ndh-trampoline-dir*' 2>/dev/null | head -1)"
  if [[ -z "$t" ]]; then
    echo "no ndh trampoline found in /nix/store — build the closure first" >&2
    return 1
  fi
  printf '%s\n' "$t"
}

# Render <script> into the per-test tmpdir and source it.
#
# The final line of each script is its dispatch — `ndh::logger:command:run <tag>
# main "$@"` — which would run main() on source. It is dropped, which is the only
# liberty this harness takes with the file under test.
render_and_source() {
  local script="$1"
  local rendered="${BATS_TEST_TMPDIR}/$(basename "$script")"
  local trampoline
  trampoline="$(ndh_trampoline)" || return 1

  sed -e "s|@nixBashTrampoline@|${trampoline}|g" \
      -e "s|@loggerTag@|test.ssh-keys|g" \
      -e '$ { /ndh::logger:command:run/d; }' \
      "$script" >"$rendered"

  # shellcheck disable=SC1090
  source "$rendered"
}

# The scripts read through `yq::get`, which closes over $inputFile. Tests set it to
# a fixture written here.
write_fixture() {
  inputFile="${BATS_TEST_TMPDIR}/keys.yaml"
  cat >"$inputFile"
  export inputFile
}
