# The console fingerprint's window is held by ONE bats case (window.bats, « a console bootstrap shows no part of its
# fingerprint … »): secret-xtrace-guard does not see it, a fingerprint being « never on the operator's screen », not
# a secret (🛡️). This check keeps that case honest at every build: on a copy of keys-reconcile.sh whose window around
# the fingerprint is removed, that case, run alone, must FAIL, and fail on the fingerprint itself. The suite as written
# runs in keys-reconcile-bats; here only the mutant.
{ pkgs, trampoline }:
let
  case = "a console bootstrap shows no part of its fingerprint";
in
pkgs.runCommand "keys-reconcile-fingerprint-window-mutant"
  {
    nativeBuildInputs = with pkgs; [
      age
      bats
      bash
      coreutils
      gawk
      findutils
      git
      gnugrep
      gnused
      hostname
      openssh
      sops
      ssh-to-age
      yq-go
    ];
    NDH_TRAMPOLINE = trampoline;
    NDH_BOOTSTRAP_PROFILE_DIR = import ../../shell.d/tests/bootstrap-profile.nix { inherit pkgs; };
  }
  ''
    cp -r ${./..} keys-reconcile.d && cp -r ${../../keys-yaml.d} keys-yaml.d && chmod -R u+w keys-reconcile.d keys-yaml.d
    s=keys-reconcile.d/keys-reconcile.sh
    begin="ndh::secret:begin \"a console bootstrap's fingerprint is compared with what the operator typed\""
    [ "$(grep -cF -- "$begin" "$s")" = 1 ] || { echo "the fingerprint's window is not in $s: this check names nothing" >&2; exit 1; }
    # The mutant: the window's begin, and the end that closes it, removed; nothing else moves.
    awk -v b="$begin" 'index($0, b) { cut = 1; next } cut && /^[[:space:]]*ndh::secret:end$/ { cut = 0; next } { print }' \
      "$s" >"$s.mutant"
    [ "$(diff "$s" "$s.mutant" | grep -c '^<')" = 2 ] || { echo "the mutant removed other than the window's two lines" >&2; exit 1; }
    mv "$s.mutant" "$s"
    grep -q '^@test "${case}' keys-reconcile.d/tests/window.bats || { echo "the case « ${case} » is gone" >&2; exit 1; }
    cd keys-reconcile.d/tests
    rc=0
    HOME=$TMPDIR bats --print-output-on-failure --filter '${case}' window.bats >$TMPDIR/out 2>&1 || rc=$?
    cat $TMPDIR/out
    if [ "$rc" = 0 ]; then
      echo "keys-reconcile-fingerprint-window-mutant: the window removed, « ${case} » still PASSED" >&2
      exit 1
    fi
    grep -q '^not ok 1 ${case}' $TMPDIR/out || { echo "the mutant failed, but not in « ${case} »" >&2; exit 1; }
    touch $out
  ''
