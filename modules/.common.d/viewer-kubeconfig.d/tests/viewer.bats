# The tool, against a stub kubectl: `config view` answers the admin kubeconfig as JSON, `get secret` answers each
# context's viewer token (or fails, for an unreachable cluster).

setup() {
  export HOME=$BATS_TEST_TMPDIR/home
  mkdir -p "$HOME/.kube" "$BATS_TEST_TMPDIR/bin"
  printf 'admin: the operator kubeconfig\n' >"$HOME/.kube/config"
  chmod 0600 "$HOME/.kube/config"
  cat >"$BATS_TEST_TMPDIR/admin.json" <<'JSON'
{"contexts":[{"name":"alpha","context":{"cluster":"alpha-c"}},{"name":"beta","context":{"cluster":"beta-c"}}],
 "clusters":[{"name":"alpha-c","cluster":{"server":"https://alpha:6443"}},{"name":"beta-c","cluster":{"server":"https://beta:6443"}}]}
JSON
  # The shebang from bash on PATH: the nix sandbox does not guarantee /usr/bin/env.
  printf '#!%s\n' "$(command -v bash)" >"$BATS_TEST_TMPDIR/bin/kubectl"
  cat >>"$BATS_TEST_TMPDIR/bin/kubectl" <<'STUB'
args="$*"
echo "$args" >>"$BATS_TEST_TMPDIR/calls"
case $args in
  *"config view"*) cat "$BATS_TEST_TMPDIR/admin.json" ;;
  *"--context alpha "*"get secret"*) printf '{"data":{"token":"%s","ca.crt":"Q0EtQQ=="}}' "$(printf tok-alpha | base64)" ;;
  *"--context beta "*"get secret"*) [[ -e $BATS_TEST_TMPDIR/beta-down ]] && exit 1
    printf '{"data":{"token":"%s","ca.crt":"Q0EtQg=="}}' "$(printf tok-beta | base64)" ;;
  *) echo "stub kubectl: unexpected $args" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "writes one viewer context per cluster, at 0600, the admin kubeconfig untouched" {
  before=$(sha256sum "$HOME/.kube/config")
  run "$TOOL"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$HOME/.kube/viewer")" = 600 ]
  [ "$(sha256sum "$HOME/.kube/config")" = "$before" ]
  [ "$(jq -r '[.contexts[].name] | join(",")' "$HOME/.kube/viewer")" = alpha-viewer,beta-viewer ]
  [ "$(jq -r '.users[] | select(.name == "beta-viewer") | .user.token' "$HOME/.kube/viewer")" = tok-beta ]
  [ "$(jq -r '.clusters[] | select(.name == "alpha-viewer") | .cluster.server' "$HOME/.kube/viewer")" = https://alpha:6443 ]
}

@test "only reads: every kubectl call is a config view or a get secret of the viewer token" {
  run "$TOOL"
  [ "$status" -eq 0 ]
  run grep -v -E '^--kubeconfig [^ ]+ (config view --raw -o json|--context [a-z]+ --request-timeout=10s -n kube-system get secret rke2lab-session-viewer-token -o json)$' "$BATS_TEST_TMPDIR/calls"
  [ "$status" -eq 1 ]
}

@test "an unreachable cluster is skipped and named, the others are written" {
  touch "$BATS_TEST_TMPDIR/beta-down"
  run "$TOOL"
  [ "$status" -eq 0 ]
  [[ $output == *"skipped beta"* ]]
  [ "$(jq -r '[.contexts[].name] | join(",")' "$HOME/.kube/viewer")" = alpha-viewer ]
}

@test "no cluster answering leaves no file at all" {
  printf '{"contexts":[{"name":"beta","context":{"cluster":"beta-c"}}],"clusters":[{"name":"beta-c","cluster":{"server":"https://beta:6443"}}]}' >"$BATS_TEST_TMPDIR/admin.json"
  touch "$BATS_TEST_TMPDIR/beta-down"
  run "$TOOL"
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/.kube/viewer" ]
  run find "$HOME/.kube" -name 'viewer.*'
  [ -z "$output" ]
}

@test "refuses to write over the admin kubeconfig" {
  before=$(sha256sum "$HOME/.kube/config")
  run "$TOOL" --out "$HOME/.kube/config"
  [ "$status" -eq 1 ]
  [ "$(sha256sum "$HOME/.kube/config")" = "$before" ]
}

@test "never sets KUBECONFIG" {
  run grep -n 'KUBECONFIG=\|export KUBECONFIG' "$TOOL"
  [ "$status" -eq 1 ]
}
