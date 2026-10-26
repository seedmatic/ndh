#!/usr/bin/env bats
# keys-reconcile's attic-tls-csr class end to end, against a real sops and step and a THROWAWAY TLS authority: a fixture
# ndh revision whose keys.yaml holds the authority's slot (its private ENCRYPTED, its ca_crt in clear), a guest's CSR
# published as attic-publish publishes it, signed by the guest's serving host key. plan measures from the record and
# the publication only; the window signs inside the trampoline's secret window and records the leaf; every refusal
# writes nothing. No private is printed.

bats_require_minimum_version 1.5.0

setup() {
  t="$BATS_TEST_TMPDIR"
  : "${NDH_TRAMPOLINE:?the ndh bash trampoline}"
  age-keygen -o "$t/age.txt" 2>/dev/null
  export SOPS_AGE_KEY_FILE="$t/age.txt"
  operator=$(age-keygen -y "$SOPS_AGE_KEY_FILE")
  ssh-keygen -q -t ed25519 -N '' -C guest -f "$t/guest"
  : "the throwaway TLS authority: a root, and its key"
  step certificate create "Test TLS" "$t/ca.crt" "$t/ca.key" --profile root-ca --no-password --insecure --kty EC --curve P-256 >/dev/null 2>&1
  : "the container's TLS key and its CSR, as attic-tls-key writes them"
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$t/tls.key" 2>/dev/null

  src="$t/src"
  mkdir -p "$src/modules/home-manager/ssh.d" "$src/catalog/attic-leaves"
  cat >"$src/.sops.yaml" <<EOF
creation_rules:
  - path_regex: '(^|/)(catalog/cache-trust\.yaml|modules/home-manager/ssh\.d/keys\.yaml)$'
    encrypted_comment_regex: 'sops:encrypted'
    age:
      - '$operator'
  - path_regex: '(^|/)\.secrets$'
    age:
      - '$operator'
EOF
  CACRT="$(<"$t/ca.crt")" CAPRIV="$(<"$t/ca.key")" GUESTPUB="$(cut -d' ' -f2 "$t/guest.pub")" \
    yq -n '
      .authorities.tls.usage = ["tls-authority"] |
      .authorities.tls.slots."26-10-10".ca_crt = strenv(CACRT) |
      .authorities.tls.slots."26-10-10".private = strenv(CAPRIV) |
      (.authorities.tls.slots."26-10-10".private | key) headComment = "sops:encrypted" |
      .keys."host-g1".type = "ssh-ed25519" | .keys."host-g1".slots."26-10-17" = {"public": strenv(GUESTPUB), "state": "serving"}
    ' >"$src/modules/home-manager/ssh.d/keys.yaml"
  printf 'caches:\n  k: v1\n  # sops:encrypted\n  s: secret\n' >"$src/catalog/cache-trust.yaml"
  printf 'a: one\n' >"$src/.secrets"
  printf '{}\n' >"$src/catalog/private-caches.json"
  (cd "$src" && for f in modules/home-manager/ssh.d/keys.yaml catalog/cache-trust.yaml .secrets; do
    sops encrypt -i --input-type yaml --output-type yaml "$f"
  done)
  yq -o json '{"keys": .keys, "authorities": .authorities} | del(.. | select(tag == "!!str" and test("^ENC\[")))' \
    "$src/modules/home-manager/ssh.d/keys.yaml" >"$t/keys.json"
  commit
  install -d -m 0755 "$t/published"
  publish attic.m1
  printf -- '- {name: g1, kind: nixos, ssh: "", ssh_opts: []}\n' >"$t/machines.yaml"
  batch ""
  printf 'tools=keys-reconcile\nexpires=%s\narmed_by=test\n' "$(($(date +%s) + 600))" >"$t/delegation"
  render
}

commit() {
  if [[ -d $src/.git ]]; then git -C "$src" -c user.email=t@t -c user.name=t commit -q -am more; else
    git -C "$src" init -q && git -C "$src" -c user.email=t@t -c user.name=t add -A && git -C "$src" -c user.email=t@t -c user.name=t commit -q -m fixture
  fi
  rev=$(git -C "$src" rev-parse HEAD)
  [[ -d $t/remote.git ]] || git init -q --bare "$t/remote.git"
  git -C "$src" push -q -f "$t/remote.git" HEAD:refs/heads/develop HEAD:refs/heads/main
}

publish() { # <CN> [signing private]: the CSR and its statement, as the guest's attic-publish writes them
  openssl req -new -key "$t/tls.key" -subj "/CN=$1" -addext "subjectAltName=DNS:$1" -out "$t/published/attic-m1.tls-csr.csr"
  printf 'seedmatic-attic v1\nclass attic-tls-csr\ncache m1\nmachine g1\nsha256 %s\n' \
    "$(sha256sum "$t/published/attic-m1.tls-csr.csr" | cut -d' ' -f1)" >"$t/published/attic-m1.tls-csr.statement"
  rm -f "$t/published/attic-m1.tls-csr.statement.sig"
  ssh-keygen -q -Y sign -f "${2:-$t/guest}" -n seedmatic-attic "$t/published/attic-m1.tls-csr.statement" </dev/null
}

batch() { # <recorded leaf path or "">
  printf '[{"class": "attic-tls-csr", "machine": "g1", "cache": "m1", "fqdn": "attic.m1", "dir": "%s", "servingPublic": "%s", "recordedLeaf": "%s"}]\n' \
    "$t/published" "$(cut -d' ' -f1,2 "$t/guest.pub")" "$1" >"$t/batch.json"
}

render() {
  local -A vars=(
    [nixBashTrampoline]="$NDH_TRAMPOLINE" [toolPath]="$PATH" [verify]="$BATS_TEST_DIRNAME/../verify.sh" [write]="$BATS_TEST_DIRNAME/../write.sh" [classes]="$BATS_TEST_DIRNAME/../classes"
    [revision]="$rev" [remote]="$t/remote.git" [batch]="$t/batch.json" [machines]="$t/machines.yaml"
    [keysJson]="$t/keys.json" [publishDir]="$t/published" [delegation]="$t/delegation" [keysJsonTool]="$t/keys-json" [ttyIn]="$t/tty" [ttyOut]="$t/prompt"
  )
  local text k
  text="$(cat "$BATS_TEST_DIRNAME/../keys-reconcile.sh")"
  for k in "${!vars[@]}"; do
    case $k in
      nixBashTrampoline | toolPath | verify | write | classes | machines | batch | keysJson) text="${text//@$k@/${vars[$k]}}" ;;
      *) text="${text//@$k@/$(printf '%q' "${vars[$k]}")}" ;;
    esac
  done
  text="${text//== 0 ]] || return 1/== $(id -u) ]] || return 1}"
  printf '%s\n' "$text" >"$t/keys-reconcile"
  ! grep -q '@[a-zA-Z]*@' "$t/keys-reconcile"
  printf '#!%s\nexit 0\n' "$BASH" >"$t/keys-json"
  chmod +x "$t/keys-json"
}

kr() { # <verb> [answer]
  printf '%s\n' "${2:-yes}" >"$t/tty"
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t HOME="$t/home" XDG_CACHE_HOME="$t/cache" XDG_STATE_HOME="$t/state" \
    bash "$t/keys-reconcile" "$1"
}

tree() { echo "$t/state/keys-reconcile/${rev:0:12}"; }
pub() { # <x509|key> <file> → the sha256 of its public key
  if [[ $1 == key ]]; then openssl pkey -in "$2" -pubout -outform DER; else openssl x509 -in "$2" -noout -pubkey | openssl pkey -pubin -outform DER; fi |
    sha256sum | cut -d' ' -f1
}

@test "plan: a guest's CSR verified against its RECORDED serving key, a leaf to sign" {
  run --separate-stderr kr plan
  [ "$status" -eq 0 ]
  [[ $output == *"✓ g1 — TLS leaf of attic.m1 to sign (3650 days)"* ]]
}

@test "window: the leaf is signed by the authority, chains, names the cache alone, carries the CSR's key, recorded" {
  run --separate-stderr kr window
  [ "$status" -eq 0 ]
  leaf="$(tree)/catalog/attic-leaves/m1.crt"
  openssl verify -CAfile "$t/ca.crt" -no-CApath -no-CAstore "$leaf"
  [ "$(openssl x509 -in "$leaf" -noout -ext subjectAltName | tail -1 | tr -d ' ')" = "DNS:attic.m1" ]
  [ "$(pub x509 "$leaf")" = "$(pub key "$t/tls.key")" ]
  ! openssl x509 -in "$leaf" -noout -text | grep -q 'CA:TRUE' || false
  openssl x509 -in "$leaf" -noout -checkend $((3000 * 86400))
  cmp "$t/published/attic-m1.tls-csr.statement" "$(tree)/catalog/attic-leaves/m1.csr.statement"
  git -C "$(tree)" log -1 --format=%B | grep -q '^keys-reconcile: sign 1 attic TLS leaf(s) at '
  [ -z "$(git -C "$(tree)" status --porcelain)" ]
}

@test "a current recorded leaf: nothing collected, nothing to sign" {
  kr window
  cp "$(tree)/catalog/attic-leaves/m1.crt" "$t/recorded.crt"
  rm -f "$t/published/"*
  batch "$t/recorded.crt"
  render
  run --separate-stderr kr plan
  [ "$status" -eq 0 ]
  [[ $output == *"= g1 — TLS leaf of attic.m1 up to date"* ]]
}

@test "mutant: a statement signed by another key than the guest's recorded one is refused" {
  ssh-keygen -q -t ed25519 -N '' -C forger -f "$t/forger"
  publish attic.m1 "$t/forger"
  run --separate-stderr kr plan
  [ "$status" -eq 4 ]
  [[ $output == *"not signed by the host key keys.yaml records as g1's serving one"* ]]
}

@test "mutant: a CSR naming another cache is refused" {
  publish attic.m2
  run --separate-stderr kr plan
  [ "$status" -eq 4 ]
  [[ $output == *"its CSR does not name exactly attic.m1"* ]]
}

@test "mutant: a CSR with another key than the recorded leaf's is refused (a new key is a declared rotation)" {
  : "a leaf recorded on another key, expired, so it is due"
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$t/other.key" 2>/dev/null
  openssl req -x509 -key "$t/other.key" -subj /CN=attic.m1 -addext subjectAltName=DNS:attic.m1 -days 1 -out "$t/stale.crt" 2>/dev/null
  batch "$t/stale.crt"
  render
  run --separate-stderr kr plan
  [ "$status" -eq 4 ]
  [[ $output == *"its CSR's key is not the recorded leaf's key"* ]]
}

@test "no « yes »: nothing signed, nothing written" {
  run --separate-stderr kr window no
  [ "$status" -eq 5 ]
  [ ! -e "$(tree)" ]
}

@test "traced on request, no byte of the authority's private reaches stdout, stderr or the trace" {
  printf '%s\n' yes >"$t/tty"
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t HOME="$t/home" XDG_CACHE_HOME="$t/cache" XDG_STATE_HOME="$t/state" \
    NDH_LOGGER_XTRACE=1 bash -x "$t/keys-reconcile" window >"$t/out" 2>"$t/trace" || true
  [ -s "$t/trace" ]
  : "every base64 line of the authority's private, and its PEM armour"
  while IFS= read -r line; do
    [[ $line == -----* || -z $line ]] && continue
    run grep -qF -- "$line" "$t/out" "$t/trace"
    [ "$status" -eq 1 ]
  done <"$t/ca.key"
  run grep -q 'PRIVATE KEY' "$t/out" "$t/trace"
  [ "$status" -eq 1 ]
}

@test "no private is ever printed, the authority's least of all" {
  run --separate-stderr kr window
  [[ $output$stderr != *"PRIVATE KEY"* ]]
  [[ $output$stderr != *"$(sed -n 2p "$t/ca.key")"* ]]
  ! grep -rq 'PRIVATE KEY' "$(tree)/catalog/attic-leaves" || false
}
