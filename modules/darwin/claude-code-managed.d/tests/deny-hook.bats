#!/usr/bin/env bats
# Feeds PreToolUse JSON to deny-hook.py. Nothing here runs the commands under test.

setup() {
  HOOK="$BATS_TEST_DIRNAME/../deny-hook.py"
  REPO=/Volumes/git-worktree-store/seedmatic/rke2lab.d/develop
  export HOME=/Users/tester
}

hook() {
  C="$1" CWD="${2:-/tmp/work}" yq -n -o=json \
    '{"hook_event_name":"PreToolUse", "permission_mode":"bypassPermissions",
      "tool_name":"Bash", "tool_input":{"command":strenv(C)}, "cwd":strenv(CWD)}' | python3 "$HOOK"
}

denied()  { [ "$status" -eq 2 ] || { echo "expected deny, got status=$status output=$output"; return 1; }; }
allowed() { [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "expected allow, got status=$status output=$output"; return 1; }; }
asked()   { [ "$status" -eq 0 ] && [[ "$output" == *'"permissionDecision": "ask"'* ]] || { echo "expected ask, got status=$status output=$output"; return 1; }; }

# --- A: a global option before the verb (the deny list's own gap) ---
@test "A kubectl -n before delete"          { run hook 'kubectl -n prod delete pod x'; denied; }
@test "A kubectl --context before apply"    { run hook 'kubectl --context bioskop-mgmt apply -f m.yaml'; denied; }
@test "A kubectl --kubeconfig=… patch"      { run hook 'kubectl --kubeconfig=/tmp/k patch cm x -p payload'; denied; }
@test "A helm -n before upgrade"            { run hook 'helm -n kube-system upgrade cilium cilium/cilium'; denied; }
@test "A helm --kube-context install"       { run hook 'helm --kube-context c install r ch'; denied; }
@test "A pulumi -C before up"               { run hook 'pulumi -C infra up --yes'; denied; }
@test "A pulumi --cwd before destroy"       { run hook 'pulumi --cwd infra destroy'; denied; }
@test "A incus --project before stop"       { run hook 'incus --project rke2lab stop node-1'; denied; }
@test "A incus nested storage volume delete" { run hook 'incus storage volume delete default v1'; denied; }
@test "A incus config set"                  { run hook 'incus config set c1 limits.cpu 4'; denied; }
@test "A home-manager --flake before switch" { run hook 'home-manager --flake . switch'; denied; }
@test "A sudo nixos-rebuild --flake boot"   { run hook 'sudo nixos-rebuild --flake .#bioskop boot'; denied; }
@test "A darwin-rebuild --rollback"         { run hook 'sudo darwin-rebuild --rollback'; denied; }

# --- aliases, measured in the CLIs' own --help (helm v3.20.2, pulumi v3.261.0) ---
@test "alias helm del"                      { run hook 'helm del r'; denied; }
@test "alias helm -n x un"                  { run hook 'helm -n x un r'; denied; }
@test "alias helm delete under flox"        { run hook 'flox activate -- helm delete r'; denied; }
@test "alias pulumi update"                 { run hook 'pulumi update --yes'; denied; }
@test "alias pulumi -C down"                { run hook 'pulumi -C infra down'; denied; }
@test "alias pulumi dn"                     { run hook 'pulumi dn --yes'; denied; }
@test "ok helm list --uninstalled"          { run hook 'helm list --uninstalled'; allowed; }
@test "ok pulumi stack ls"                  { run hook 'pulumi stack ls'; allowed; }

# --- B: launchers the deny list does not strip ---
@test "B bash -c"                           { run hook "bash -c 'kubectl apply -f x.yaml'"; denied; }
@test "B sh -lc"                            { run hook 'sh -lc "helm uninstall r"'; denied; }
@test "B flox activate -c"                  { run hook "flox activate -c 'kubectl delete ns x'"; denied; }
@test "B flox activate -d -- with flag"     { run hook 'flox activate -d . -- kubectl -n x apply -f y'; denied; }
@test "B nix run nixpkgs#kubectl --"        { run hook 'nix run nixpkgs#kubectl -- delete pod x'; denied; }
@test "B nix run attr alias helm"           { run hook 'nix run nixpkgs#kubernetes-helm -- upgrade r c'; denied; }
@test "B nix shell -c"                      { run hook 'nix shell nixpkgs#kubectl nixpkgs#jq -c kubectl apply -f y'; denied; }
@test "B nix develop --command"             { run hook 'nix develop .#ci --command pulumi up'; denied; }
@test "B nix-shell --run"                   { run hook "nix-shell -p kubectl --run 'kubectl apply -f y'"; denied; }
@test "B ssh remote rebuild"                { run hook 'ssh bioskop sudo nixos-rebuild switch'; denied; }
@test "B absolute program path"             { run hook '/run/current-system/sw/bin/kubectl delete pod x'; denied; }
@test "B env assignment"                    { run hook 'env KUBECONFIG=/k kubectl apply -f y'; denied; }
@test "B env -u"                            { run hook 'env -u FOO incus delete c1'; denied; }
@test "B env -S split-string"               { run hook "env -S 'kubectl apply -f y'"; denied; }
@test "B sudo -u root"                      { run hook 'sudo -u root incus delete c1'; denied; }
@test "B timeout with signal"               { run hook 'timeout -s KILL 30 helm upgrade r c'; denied; }
@test "B xargs -n1"                         { run hook 'echo p | xargs -n1 kubectl delete pod'; denied; }
@test "B watch"                             { run hook 'watch -n 5 kubectl apply -f y'; denied; }
@test "B eval"                              { run hook 'eval "kubectl apply -f y"'; denied; }
@test "B command substitution"              { run hook 'echo "$(kubectl delete pod x)"'; denied; }
@test "B backticks"                         { run hook 'echo `pulumi destroy --yes`'; denied; }
@test "B process substitution"              { run hook 'diff <(kubectl apply -f y) /dev/null'; denied; }
@test "B heredoc fed to bash"               { run hook "$(printf "bash <<'EOF'\nkubectl apply -f y\nEOF")"; denied; }
@test "B compound after cd"                 { run hook 'cd /tmp && kubectl -n y delete pod z'; denied; }
@test "B newline-separated"                 { run hook "$(printf 'ls\nhelm -n x uninstall r')"; denied; }
@test "B nested wrappers"                   { run hook "sudo env FOO=1 bash -c 'nix run nixpkgs#kubectl -- -n x delete pod y'"; denied; }

# --- C: spelling variants ---
@test "C rm -fr in a repo"                  { run hook 'rm -fr build' "$REPO"; asked; }
@test "C rm -Rf in a repo"                  { run hook 'rm -Rf build' "$REPO"; asked; }
@test "C rm -r -f in a repo"                { run hook 'rm -r -f build' "$REPO"; asked; }
@test "C rm --recursive --force in a repo"  { run hook 'rm --recursive --force build' "$REPO"; asked; }
@test "C rm -r ~/.claude (no force)"        { run hook 'rm -r ~/.claude'; asked; }
@test "C rm -r \$HOME/.claude"              { run hook 'rm -r "$HOME/.claude"'; asked; }
@test "C rm -r .claude from HOME"           { run hook 'rm -r .claude' /Users/tester; asked; }
@test "C cd \$HOME then rm -rf .claude"      { run hook 'cd $HOME && rm -rf .claude'; asked; }
@test "C cd \"\$HOME\" then rm -rf .claude"    { run hook 'cd "$HOME" && rm -rf .claude'; asked; }
@test "C cd \$HOME/.claude then rm -rf a dir" { run hook 'cd $HOME/.claude && rm -rf .scratchpad.d'; asked; }
@test "C cd \$d then rm -rf .claude"         { run hook 'cd $d && rm -rf .claude'; denied; }
@test "C mv absolute home path"             { run hook 'mv /Users/tester/.claude /tmp/old'; denied; }
@test "C mv \$HOME/.claude.json"            { run hook 'mv "$HOME/.claude.json" /tmp/x'; denied; }
@test "C mv into ~/.claude"                 { run hook 'mv settings.json ~/.claude/settings.json'; denied; }
@test "C mv config into its scratchpad"     { run hook 'mv ~/.claude/settings.json ~/.claude/.scratchpad.d/cutover/'; denied; }
@test "C mv .. out of the scratchpad"       { run hook 'mv x ~/.claude/.scratchpad.d/../settings.json'; denied; }
@test "C mv to a scratchpad lookalike"      { run hook 'mv x ~/.claude/.scratchpad.dx/'; denied; }
@test "ok mv into ~/.claude/.scratchpad.d"  { run hook 'mv notes.md ~/.claude/.scratchpad.d/cutover/'; allowed; }
@test "ok mv into \$HOME scratchpad"         { run hook 'mv notes.md "$HOME/.claude/.scratchpad.d/cutover/notes.md"'; allowed; }

# --- D: Pulumi through the Automation API ---
@test "D nix run .#grow -- stack up"        { run hook 'nix run .#grow -- dev up'; denied; }
@test "D rke2lab-grow stack up"             { run hook 'rke2lab-grow dev up --target x'; denied; }
@test "D grow preview stays allowed"        { run hook 'nix run .#grow -- dev preview'; allowed; }
@test "D grow default (preview) allowed"    { run hook 'nix run .#grow -- dev'; allowed; }
@test "D java seed-outcluster Main → ask"   { run hook 'java -cp app.jar io.seedmatic.rke2lab.controlplane.Main seed'; asked; }
@test "D mvnw exec:java seed-outcluster → ask" { run hook 'flox activate -- ./mvnw -pl :seed-outcluster -am exec:java'; asked; }
# Known limits, asserted so that a change in behaviour is noticed — a textual hook cannot see these:
@test "D LIMIT script file content"         { run hook './scripts/deploy.sh'; allowed; }
@test "D LIMIT make target"                 { run hook 'make up'; allowed; }
@test "D LIMIT interpreter code"            { run hook "python3 -c \"import subprocess; subprocess.run(['kubectl','apply','-f','y'])\""; allowed; }
@test "D LIMIT shell alias"                 { run hook 'k delete pod x'; allowed; }
@test "D LIMIT bash script argument"        { run hook 'bash ./deploy.sh'; allowed; }

# --- no false positives on read-only work ---
@test "ok kubectl get"                      { run hook 'kubectl -n x get pods -o wide'; allowed; }
@test "ok kubectl get a pod named delete-me" { run hook 'kubectl get pod delete-me'; allowed; }
@test "ok kubectl auth can-i delete"        { run hook 'kubectl auth can-i delete pods'; allowed; }
@test "ok kubectl --dry-run is still apply" { run hook 'kubectl apply --dry-run=client -f y'; denied; }
@test "ok helm template with install key"   { run hook 'helm template r ch --set install.crds=true'; allowed; }
@test "ok pulumi preview"                   { run hook 'pulumi preview --diff'; allowed; }
@test "ok pulumi stack output upstream"     { run hook 'pulumi stack output upstream-url'; allowed; }
@test "ok incus list"                       { run hook 'incus list --format csv'; allowed; }
@test "ok incus info of shell-box"          { run hook 'incus info shell-box'; allowed; }
@test "ok nixos-rebuild build"              { run hook 'nixos-rebuild build --flake .#bioskop'; allowed; }
@test "ok darwin-rebuild build flake attr"  { run hook 'darwin-rebuild build --flake .#switch'; allowed; }
@test "ok rm -r without force"              { run hook 'rm -r target/tmp'; allowed; }
@test "ok rm -f a file"                     { run hook 'rm -f /tmp/x.json'; allowed; }
@test "ok mv elsewhere"                     { run hook 'mv a.txt b.txt'; allowed; }
@test "ok cat Claude settings"              { run hook 'cat ~/.claude/settings.json'; allowed; }
@test "ok mvnw test"                        { run hook 'flox activate -- ./mvnw -pl :seed-outcluster -am test -DskipTests=false'; allowed; }
@test "ok ssh read"                         { run hook 'ssh bioskop uptime'; allowed; }
@test "ok commit message quoting a verb"    { run hook 'git commit -m "kubectl delete is refused"'; allowed; }
@test "ok grep for a verb"                  { run hook "grep -rn 'kubectl apply' docs"; allowed; }
@test "ok non-Bash tool"                    { run bash -c "echo '{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/x\"}}' | python3 '$HOOK'"; allowed; }

# --- robustness: every failure refuses (a PreToolUse hook that errors fails OPEN) ---
@test "robust invalid JSON on stdin"        { run bash -c "echo 'not json' | python3 '$HOOK'"; denied; }
@test "robust unbalanced quote"             { run hook "kubectl get pods 'oops"; denied; }
@test "robust unbalanced substitution"      { run hook 'echo $(kubectl get pods'; denied; }
@test "robust missing command field"        { run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{}}' | python3 '$HOOK'"; denied; }
@test "robust nesting deeper than followed" { run hook 'watch watch watch watch watch watch watch watch watch watch ls'; denied; }

# --- rm: recursive forced removal passes in a scratch directory, and ASKS elsewhere ---
@test "rm ok scratch /tmp"                  { run hook 'rm -rf /tmp/mm2'; allowed; }
@test "rm ok scratch /private/tmp"          { run hook 'rm -rf /private/tmp/flox-sb'; allowed; }
@test "rm ok relative under /tmp"           { run hook 'rm -rf mmcheck' /private/tmp; allowed; }
@test "rm ok a repo's .scratchpad.d"        { run hook 'rm -rf .scratchpad.d/topic' "$REPO"; allowed; }
@test "rm ok quoted path with a space"      { run hook 'rm -rf "/tmp/a b"'; allowed; }
@test "rm asks an unresolved variable"      { run hook 'rm -rf $T'; asked; }
@test "rm asks a glob"                      { run hook 'rm -rf /tmp/x/*'; asked; }
@test "rm asks / even unforced"             { run hook 'rm -r /'; asked; }
@test "rm asks ~"                           { run hook 'rm -rf ~'; asked; }
@test "rm asks a .. escape out of /tmp"     { run hook 'rm -rf /tmp/../Users/tester'; asked; }
@test "rm asks /nix/store"                  { run hook 'sudo rm -rf /nix/store/abc-x'; asked; }
@test "rm asks under flox"                  { run hook 'flox activate -- rm -rf build' "$REPO"; asked; }

# --- heredocs: data unless something runs them ---
@test "heredoc commit message naming verbs" { run hook "$(printf "git commit -q -F - <<'EOF'\nkubectl -n x delete pod y is a gesture\npulumi up too\nEOF")"; allowed; }
@test "heredoc in \$(cat) for -m"           { run hook "$(printf "git commit -m \"\$(cat <<'EOF'\npulumi up is the operator's\nEOF\n)\"")"; allowed; }
@test "heredoc with prose apostrophes"      { run hook "$(printf "cat > /tmp/n.md <<EOF\nit's the operator's call, don't\nEOF")"; allowed; }
@test "heredoc piped into bash"             { run hook "$(printf "cat <<'EOF' | bash\nkubectl apply -f y\nEOF")"; denied; }
@test "heredoc into sudo"                   { run hook "$(printf "sudo tee /etc/x <<'EOF'\nkubectl delete pod y\nEOF")"; denied; }
@test "heredoc unquoted runs \$()"          { run hook "$(printf "cat <<EOF\n\$(kubectl delete pod y)\nEOF")"; denied; }
@test "heredoc quoted keeps \$() literal"   { run hook "$(printf "cat <<'EOF'\n\$(kubectl delete pod y)\nEOF")"; allowed; }
@test "heredoc then a real command"         { run hook "$(printf "cat > /tmp/x <<'EOF'\nhello\nEOF\nkubectl delete pod y")"; denied; }

# --- parse robustness: real commands of 2026-10-07 that a fail-closed parser refused ---
@test "parse paren inside quotes in \$()"   { run hook "echo \"calls: \$(git grep -c 'packageAnnotations(' -- '*.java' | wc -l)\""; allowed; }
@test "parse apostrophe in a comment"       { run hook "$(printf "for d in a b; do\n  # it is fleet's, counted there\n  echo \$d\ndone")"; allowed; }
@test "parse two heredocs on one line"      { run hook "$(printf "git commit -F - <<'EOF' && git commit -F - <<'EOF2'\nthe operator's call\nEOF\nit's done\nEOF2")"; allowed; }
@test "parse ANSI-C \$'' string"             { run hook "C=\$'it\\'s a\\nline'; echo \"\$C\""; allowed; }
@test "parse still sees a verb after two heredocs" { run hook "$(printf "cat <<'A' && cat <<'B'\nx\nA\ny\nB\nkubectl delete pod z")"; denied; }
@test "parse comment does not hide the next line" { run hook "$(printf "# kubectl delete here is prose\nkubectl delete pod z")"; denied; }
@test "parse ANSI-C string still analysed"  { run hook "bash -c \$'kubectl delete pod z'"; denied; }

# --- the operator's keyring material (verbs.json list_path_rules): the managed Read()/Edit() rules govern the
#     file tools only, so the hook refuses a Bash command reaching it. A first line: a path built at run time escapes.
KEY=/Volumes/git-bare-store/nxmatic/keyhole.git/.ssh
RING=/Volumes/git-worktree-store/nxmatic/keyhole.d/keyring
@test "keyring: cat of the key"                 { run hook "cat $KEY/id_ed25519"; denied; }
@test "keyring: ssh-keygen -y of the key"       { run hook "ssh-keygen -y -f $KEY/id_ed25519"; denied; }
@test "keyring: cp of the worktree"             { run hook "cp -r $RING /tmp/x"; denied; }
@test "keyring: sops -d in the worktree"        { run hook "sops -d --input-type binary $RING/gpg.master~rehydrate.enc.sh"; denied; }
@test "keyring: cd then cat"                    { run hook "cd $RING; cat gpg.master~rehydrate.sh"; denied; }
@test "keyring: cd chain into it"               { run hook 'cd /Volumes/git-worktree-store/nxmatic/keyhole.d && cd keyring && cat x'; denied; }
@test "keyring: relative path from its parent"  { run hook 'cat keyring/gpg.master~rehydrate.sh' /Volumes/git-worktree-store/nxmatic/keyhole.d; denied; }
@test "keyring: a glob under it"                { run hook 'tar czf /tmp/k.tgz keyring/*' /Volumes/git-worktree-store/nxmatic/keyhole.d; denied; }
@test "keyring: an option value"                { run hook "ssh -i $KEY/id_ed25519 host"; denied; }
@test "keyring: --opt=path"                     { run hook "git --git-dir=$KEY/.. log"; denied; }
@test "keyring: inside a -c script"             { run hook "python3 -c \"open('$KEY/id_ed25519').read()\""; denied; }
@test "keyring: a session whose cwd is inside"  { run hook 'ls' "$RING"; denied; }
@test "keyring: relative .ssh from the bare"    { run hook 'cat .ssh/id_ed25519' /Volumes/git-bare-store/nxmatic/keyhole.git; denied; }
@test "keyring: the main worktree stays free"   { run hook 'git -C /Volumes/git-worktree-store/nxmatic/keyhole.d/main log -1'; allowed; }
@test "keyring: a sibling name stays free"      { run hook 'ls /Volumes/git-worktree-store/nxmatic/keyhole.d/keyring-archive'; allowed; }
@test "keyring: the bare's refs stay free"      { run hook 'git -C /Volumes/git-bare-store/nxmatic/keyhole.git for-each-ref'; allowed; }

# --- the seat identities (verbs.json list_path_rules, store_rules, text_rules): the seedmatic/ entries of the
#     operator's pass store, its claude-home replica, and pass naming them. A ~ rule resolves under the session's HOME.
STORE=/Users/tester/.local/share/password-store
REPLICA=/Volumes/git-worktree-store/nxmatic/claude-home.d/pass/seedmatic
@test "seedmatic: gpg -d of an entry"           { run hook "gpg -d $STORE/seedmatic/host-key/bioskop.gpg"; denied; }
@test "seedmatic: the ~ spelling"               { run hook 'cat ~/.local/share/password-store/seedmatic/x.gpg'; denied; }
@test "seedmatic: the \$HOME spelling in -c"    { run hook "bash -c 'cp -r \$HOME/.local/share/password-store/seedmatic /tmp/x'"; denied; }
@test "seedmatic: cd into the store then cat"   { run hook 'cd ~/.local/share/password-store && cat seedmatic/x.gpg'; denied; }
@test "seedmatic: a store dir variable"         { run hook 'PASSWORD_STORE_DIR=~/.local/share/password-store/seedmatic pass show x'; denied; }
@test "seedmatic: the replica checkout"         { run hook "cat $REPLICA/.gpg-id"; denied; }
@test "seedmatic: pass show"                    { run hook 'pass show seedmatic/host-key/bioskop'; denied; }
@test "seedmatic: pass with no verb"            { run hook 'pass seedmatic/host-key/bioskop'; denied; }
@test "seedmatic: pass ls of an entry"          { run hook 'pass ls seedmatic/host-key/bioskop'; denied; }
@test "seedmatic: pass -c behind sudo"          { run hook 'sudo -u nxmatic pass show -c seedmatic/x'; denied; }
@test "seedmatic: pass init -p"                 { run hook 'pass init -p seedmatic 08C86550EBC4589C!'; denied; }
@test "seedmatic: pass through nix run"         { run hook 'nix run nixpkgs#pass -- show seedmatic/x'; denied; }
@test "seedmatic: pass grep decrypts it all"    { run hook 'pass grep ssh-ed25519'; denied; }
@test "seedmatic: a replica blob"               { run hook 'git -C /Volumes/git-bare-store/nxmatic/claude-home.git show pass/seedmatic:host-key/bioskop.gpg'; denied; }
@test "seedmatic: a replica blob by full ref"   { run hook 'git -C /Volumes/git-bare-store/nxmatic/claude-home.git cat-file -p refs/heads/pass/seedmatic:.gpg-id'; denied; }
@test "seedmatic: pass find prints names"       { run hook 'pass find seedmatic'; allowed; }
@test "seedmatic: another entry stays free"     { run hook 'pass show web/forge'; allowed; }
@test "seedmatic: a sibling name stays free"    { run hook "ls $STORE/seedmatic-archive"; allowed; }
@test "seedmatic: the replica's log stays free" { run hook 'git -C /Volumes/git-bare-store/nxmatic/claude-home.git log --format=%h pass/seedmatic'; allowed; }
@test "seedmatic: the store's git log stays free" { run hook "git -C $STORE log -1 --format=%h -- seedmatic"; allowed; }

# --- gpg (verbs.json option_rules): a session never decrypts with, nor exports, the operator's secret keys.
#     gpg takes a unique prefix of a long option, clusters short ones, and decrypts when given no command.
@test "gpg: -d"                                 { run hook 'gpg -d /tmp/x.gpg'; denied; }
@test "gpg: --decrypt"                          { run hook 'gpg --batch --decrypt /tmp/x.gpg'; denied; }
@test "gpg: a unique prefix --decr"             { run hook 'gpg --decr /tmp/x.gpg'; denied; }
@test "gpg: -d clustered as -qd"                { run hook 'gpg -qd /tmp/x.gpg'; denied; }
@test "gpg: --decrypt-files"                    { run hook 'gpg --decrypt-files /tmp/x.gpg'; denied; }
@test "gpg: no command decrypts its input"      { run hook 'gpg -o /tmp/out /tmp/x.gpg'; denied; }
@test "gpg: no command, from a pipe"            { run hook 'cat /tmp/x.gpg | gpg --batch'; denied; }
@test "gpg: --export-secret-keys"               { run hook 'gpg --armor --export-secret-keys 074DF25347508C66'; denied; }
@test "gpg: --export-secret-subkeys"            { run hook 'gpg --export-secret-subkeys 08C86550EBC4589C!'; denied; }
@test "gpg: a prefix --export-secret-key"       { run hook 'gpg --export-secret-key 074DF25347508C66'; denied; }
@test "gpg: gpg2 behind sudo"                   { run hook 'sudo -u nxmatic gpg2 -d /tmp/x.gpg'; denied; }
@test "gpg: through env"                        { run hook 'env GNUPGHOME=/tmp/g gpg --decrypt /tmp/x.gpg'; denied; }
@test "gpg: through nix run"                    { run hook 'nix run nixpkgs#gnupg -- -d /tmp/x.gpg'; denied; }
@test "gpg: through nix shell -c"               { run hook 'nix shell nixpkgs#gnupg -c gpg -d /tmp/x.gpg'; denied; }
@test "gpg: inside a -c script"                 { run hook "bash -c 'gpg -d /tmp/x.gpg > /tmp/y'"; denied; }
@test "gpg: gpgtar --decrypt"                   { run hook 'gpgtar --decrypt -C /tmp/out /tmp/a.gpgtar'; denied; }
@test "gpg: gpgtar a unique prefix --decr"      { run hook 'gpgtar --decr /tmp/a.gpgtar'; denied; }
@test "gpg: gpgtar -x clustered as -vx"         { run hook 'gpgtar -vx /tmp/a.gpgtar'; denied; }
@test "gpg: gpgtar a d in -C's value"           { run hook 'gpgtar -Cdir --list-archive /tmp/a.gpgtar'; allowed; }
@test "gpg: --verify stays free"                { run hook 'gpg --verify /tmp/x.sig /tmp/x'; allowed; }
@test "gpg: a public --export stays free"       { run hook 'gpg --armor --export 074DF25347508C66'; allowed; }
@test "gpg: --export-ssh-key stays free"        { run hook 'gpg --export-ssh-key 074DF25347508C66'; allowed; }
@test "gpg: -K stays free"                      { run hook 'gpg -K --with-keygrip'; allowed; }
@test "gpg: --list-packets --list-only free"    { run hook 'gpg --batch --list-only --list-packets /tmp/x.gpg'; allowed; }
@test "gpg: a d in -r's value stays free"       { run hook 'gpg -rdave -e /tmp/x'; allowed; }
@test "gpg: --dearmor stays free"               { run hook 'gpg --dearmor < /tmp/k.asc > /tmp/k.gpg'; allowed; }

# --- security's additions (2026-10-16): publishing, keychain, guards, public history, keys ---
@test "pub: cachix push"                        { run hook 'cachix push seedmatic ./result'; denied; }
@test "pub: cachix -c before watch-store"       { run hook 'cachix -c /tmp/c.dhall watch-store seedmatic'; denied; }
@test "pub: attic push"                         { run hook 'attic push cluster ./result'; denied; }
@test "pub: nix copy --to"                      { run hook 'nix copy --to s3://cache ./result'; denied; }
@test "pub: nix copy --to=…"                    { run hook 'nix copy --to=https://cache.example ./result'; denied; }
@test "pub: cachix push through flox"           { run hook 'flox activate -- cachix push seedmatic ./result'; denied; }
@test "pub: nix copy --to file://"              { run hook 'nix copy --to file:///tmp/cache ./result'; denied; }
@test "pub: nix copy --to a bare path"          { run hook 'nix copy --to /tmp/cache ./result'; denied; }
@test "pub: nix copy -L --to http:// via flox"  { run hook 'flox activate -- nix copy -L --to http://cache:8080 ./result'; denied; }
@test "ok nix copy --to ssh-ng:// a guest"      { run hook 'nix copy --to ssh-ng://bioskop-nixos ./result'; allowed; }
@test "ok nix copy --to=ssh://"                 { run hook 'nix copy --to=ssh://nikopol-nixos ./result'; allowed; }
@test "ok nix copy --from"                      { run hook 'nix copy --from https://cache.nixos.org /nix/store/x'; allowed; }
@test "ok cachix use"                           { run hook 'cachix use seedmatic'; allowed; }
@test "keychain: find-generic-password -w"      { run hook 'security find-generic-password -s seedmatic -w'; denied; }
@test "keychain: find-internet-password -w"     { run hook 'security find-internet-password -s github.com -w'; denied; }
@test "keychain: -g prints the secret"          { run hook 'security find-generic-password -g -s seedmatic'; denied; }
@test "keychain: dump-keychain"                 { run hook 'security dump-keychain -d'; denied; }
@test "ok security find-certificate"            { run hook 'security find-certificate -a -p'; allowed; }
@test "guard: git commit --no-verify"           { run hook 'git commit --no-verify -m x'; denied; }
@test "guard: git -C push --no-verify"          { run hook 'git -C /tmp/r push --no-verify origin feature/x'; denied; }
@test "guard: git commit -n"                    { run hook 'git commit -n -m x'; denied; }
@test "guard: git commit -an clustered"         { run hook 'git commit -an'; denied; }
@test "guard: git commit -nm clustered"         { run hook 'git commit -nm x'; denied; }
@test "ok git commit -m with an n in its value" { run hook 'git commit -mfinal'; allowed; }
@test "ok git commit -am"                       { run hook 'git commit -am x'; allowed; }
@test "ok git push -n is a dry run"             { run hook 'git push -n origin feature/x'; allowed; }
@test "guard: git -c core.hooksPath="           { run hook 'git -c core.hooksPath=/dev/null commit -m x'; denied; }
@test "guard: the refusals name today's commit recipe" {
  for c in 'git -c core.hooksPath=/dev/null commit -m x' 'GIT_CONFIG_GLOBAL=/dev/null git commit -m x' 'git commit --no-verify -m x' 'git commit -n -m x'; do
    run hook "$c"; denied; [[ "$output" == *'plain `git commit`'* ]] || { echo "no recipe for: $c"; false; }
  done
}
@test "guard: git -ccore.hooksPath= glued"      { run hook 'git -ccore.hookspath=/tmp commit -m x'; denied; }
@test "guard: git -c filter.sops-*"             { run hook 'git -c filter.sops-keyring.clean=cat add .secrets'; denied; }
@test "guard: GIT_CONFIG_GLOBAL before commit"  { run hook 'GIT_CONFIG_GLOBAL=/dev/null git commit -m x'; denied; }
@test "guard: GIT_CONFIG_NOSYSTEM before rebase" { run hook 'GIT_CONFIG_NOSYSTEM=1 git rebase develop'; denied; }
@test "guard: env GIT_CONFIG_GLOBAL before am"  { run hook 'env GIT_CONFIG_GLOBAL=/dev/null git am x.patch'; denied; }
@test "ok GIT_CONFIG_GLOBAL before git log"     { run hook 'GIT_CONFIG_GLOBAL=/dev/null git log -1'; allowed; }
@test "ok git -c user.name commit"              { run hook 'git -c user.name=x commit -m y'; allowed; }
@test "history: push --force develop"           { run hook 'git push --force origin develop'; denied; }
@test "history: push -f main"                   { run hook 'git push -f origin main'; denied; }
@test "history: push +develop"                  { run hook 'git push origin +develop'; denied; }
@test "history: push lease to refs/heads/main"  { run hook 'git push --force-with-lease origin HEAD:refs/heads/main'; denied; }
@test "history: forced push, no refspec"        { run hook 'git push --force'; denied; }
@test "history: delete remote develop"          { run hook 'git push origin --delete develop'; denied; }
@test "history: delete via :main"               { run hook 'git push origin :main'; denied; }
@test "ok forced push of a feature branch"      { run hook 'git push --force-with-lease origin feature/x'; allowed; }
@test "ok push develop"                         { run hook 'git push origin develop'; allowed; }
@test "ok delete a feature branch"              { run hook 'git push origin --delete feature/x'; allowed; }
@test "keys: cat an ssh private key"            { run hook 'cat ~/.ssh/id_ed25519'; denied; }
@test "keys: the age identities"                { run hook 'cat ~/.config/sops/age/keys.txt'; denied; }
@test "switch: ndh-switch by name"              { run hook 'ndh-switch nikopol 0123abcd'; allowed; }
@test "switch: ndh-switch from the system profile" { run hook '/run/current-system/sw/bin/ndh-switch bioskop 0123abcd'; allowed; }
@test "switch: ndh-switch from a pushed revision" { run hook 'nix run github:seedmatic/ndh/0123abcd#ndh-switch -- bioskop 0123abcd'; allowed; }
@test "switch: a local ndh-switch copy"         { run hook './ndh-switch bioskop 0123abcd'; denied; }
@test "switch: an ndh-switch under /tmp"        { run hook '/tmp/x/ndh-switch bioskop 0123abcd'; denied; }
@test "switch: raw darwin-rebuild stays denied" { run hook 'sudo darwin-rebuild switch --flake github:seedmatic/ndh/0123abcd#bioskop'; denied; }
@test "switch: raw nixos-rebuild stays denied"  { run hook 'nixos-rebuild switch --target-host root@nixos.bioskop --flake .#bioskop-nixos'; denied; }
@test "operator tool: ssh-keys-certify" { run hook 'ssh-keys-certify --dry-run'; denied; }
@test "operator tool: ssh-keys-renew" { run hook 'ssh-keys-renew --dry-run'; denied; }
@test "operator tool: attic-leaf-sign" { run hook 'attic-leaf-sign --dry-run'; denied; }
@test "operator tool: incus-cluster-cert-renew" { run hook 'incus-cluster-cert-renew --dry-run'; denied; }
@test "operator tool: ndh-keyring" { run hook 'ndh-keyring --dry-run'; denied; }
@test "operator tool: keys-reconcile window" { run hook 'keys-reconcile window'; denied; }
@test "operator tool: by its store path" { run hook '/nix/store/abc-ssh-keys-renew/bin/ssh-keys-renew --revoke-host x'; denied; }
@test "operator tool: nix run of a pushed revision" { run hook 'nix run github:seedmatic/ndh/0123abcd#ssh-keys-certify -- --apply'; denied; }
@test "operator tool: nix run by revision of the bare" { run hook 'nix run "git+file:///Volumes/git-bare-store/seedmatic/ndh.git?rev=0123abcd#attic-leaf-sign"'; denied; }
@test "operator tool: inside a bash -c" { run hook "bash -c 'ndh-keyring status'"; denied; }
@test "operator tool: through flox and sudo" { run hook 'flox activate -- sudo incus-cluster-cert-renew'; denied; }
@test "operator tool: over ssh" { run hook 'ssh darwin.nikopol ndh-keyring host-key nikopol'; denied; }
@test "ok reading an operator tool's source" { run hook 'cat modules/.common.d/ssh-keys-certify.d/certify.sh'; allowed; }
@test "ok building an operator tool by revision" { run hook 'nix build github:seedmatic/ndh/0123abcd#ssh-keys-certify'; allowed; }
@test "ops: ndh-ops arm is the operator's"      { run hook 'ndh-ops arm --hours 4 --tools ssh-keys-renew'; denied; }
@test "ops: ndh-ops arm from a pushed revision" { run hook 'nix run github:seedmatic/ndh/0123abcd#ndh-ops -- arm --hours 4 --tools ndh-keyring'; denied; }
@test "ops: writing the delegation by sudo tee" { run hook 'echo tools=ndh-keyring | sudo tee /var/db/ndh-ops/delegation'; denied; }
@test "ops: a local ndh-ops copy"               { run hook './ndh-ops ssh-keys-renew --apply'; denied; }
@test "ok ndh-ops runs a tool, the delegation decides" { run hook 'nix run github:seedmatic/ndh/0123abcd#ndh-ops -- ssh-keys-renew --apply'; allowed; }
@test "ok ndh-ops status"                       { run hook 'ndh-ops status'; allowed; }
@test "ok ndh-ops disarm"                       { run hook 'ndh-ops disarm'; allowed; }
@test "keys: the vz-recover private, by name"    { run hook 'ssh -i ~/.ssh/vz-recover vzhost.nikopol tart list'; denied; }
@test "ok vz-recover through its Host block"     { run hook 'ssh vzrecover.nikopol list'; allowed; }
@test "ok vz-recover probe, BatchMode"           { run hook 'ssh -o BatchMode=yes -o ConnectTimeout=5 vzrecover.nikopol probe'; allowed; }
@test "ok vz-recover restart one VM"             { run hook 'ssh -qT vzrecover.nikopol restart nikopol-nixos'; allowed; }
@test "ok vz-recover rollback, -oKey=value"      { run hook 'ssh -oBatchMode=yes vzrecover.nikopol rollback nikopol'; allowed; }
@test "ok vz-recover restart-access"             { run hook 'ssh vzrecover.nikopol restart-access nikopol'; allowed; }
@test "vz: a login shell (no remote command)"    { run hook 'ssh vzrecover.nikopol'; denied; }
@test "vz: an arbitrary remote command"          { run hook 'ssh vzrecover.nikopol id'; denied; }
@test "vz: tart directly"                        { run hook 'ssh vzrecover.nikopol tart list'; denied; }
@test "vz: a verb with a metacharacter"          { run hook "ssh vzrecover.nikopol 'list;id'"; denied; }
@test "vz: a verb then a second command word"    { run hook "ssh vzrecover.nikopol 'restart nikopol-nixos && id'"; denied; }
@test "vz: two arguments"                        { run hook 'ssh vzrecover.nikopol restart a b'; denied; }
@test "vz: probe takes no argument"              { run hook 'ssh vzrecover.nikopol probe nikopol'; denied; }
@test "vz: a VM name in upper case"              { run hook 'ssh vzrecover.nikopol restart Nikopol'; denied; }
@test "vz: a VM name with a dot"                 { run hook 'ssh vzrecover.nikopol restart a.b'; denied; }
@test "vz: a substitution in the argument"       { run hook "ssh vzrecover.nikopol restart '\$(id)'"; denied; }
@test "vz: -N"                                   { run hook 'ssh -N vzrecover.nikopol list'; denied; }
@test "vz: -L forwarding"                        { run hook 'ssh -L 1:localhost:1 vzrecover.nikopol list'; denied; }
@test "vz: -R forwarding"                        { run hook 'ssh -R 2222:localhost:22 vzrecover.nikopol list'; denied; }
@test "vz: -D socks"                             { run hook 'ssh -D 1080 vzrecover.nikopol list'; denied; }
@test "vz: -t a tty"                             { run hook 'ssh -t vzrecover.nikopol list'; denied; }
@test "vz: -o RemoteCommand"                     { run hook "ssh -o 'RemoteCommand=bash' vzrecover.nikopol list"; denied; }
@test "vz: -oLocalForward"                       { run hook "ssh '-oLocalForward=1 localhost:1' vzrecover.nikopol list"; denied; }
@test "vz: -o ProxyCommand"                      { run hook "ssh -o 'ProxyCommand nc %h %p' vzrecover.nikopol list"; denied; }
@test "vz: -F another config"                    { run hook 'ssh -F /tmp/c vzrecover.nikopol list'; denied; }
@test "vz: as a jump host"                       { run hook 'ssh -J vzrecover.nikopol other.host true'; denied; }
@test "vz: an ssh:// destination"                { run hook 'ssh ssh://vzrecover.nikopol id'; denied; }
@test "vz: upper case"                           { run hook 'ssh VZRECOVER.nikopol id'; denied; }
@test "vz: user@ form"                           { run hook 'ssh nxmatic@vzrecover.nikopol id'; denied; }
@test "vz: behind bash -c"                       { run hook "bash -c 'ssh vzrecover.nikopol id'"; denied; }
@test "vz: scp"                                  { run hook 'scp /tmp/x vzrecover.nikopol:/tmp/x'; denied; }
@test "vz: sftp"                                 { run hook 'sftp vzrecover.nikopol'; denied; }
@test "vz: rsync"                                { run hook 'rsync -a /tmp/x vzrecover.nikopol:/tmp/'; denied; }
@test "vz: sshfs"                                { run hook 'sshfs vzrecover.nikopol:/ /tmp/m'; denied; }
@test "ok another host keeps its remote command" { run hook 'ssh nikopol-nixos.local true'; allowed; }
@test "vz: \$( ) as the VM name"                 { run hook 'ssh vzrecover.nikopol restart $(id -un)'; denied; }
@test "vz: a backtick as the verb"               { run hook 'ssh vzrecover.nikopol `echo list`'; denied; }
@test "vz: \$( ) inside double quotes"           { run hook 'ssh vzrecover.nikopol "restart $(id)"'; denied; }
@test "vz: a host variant (trailing domain)"     { run hook 'ssh vzrecover.nikopol.local id'; denied; }
@test "vz: a host variant (dash)"                { run hook 'ssh vz-recover.nikopol id'; denied; }
@test "vz: the host built by a substitution"     { run hook 'ssh vzrecover.$(echo nikopol) id'; denied; }
@test "vz: -i the key by another spelling"       { run hook 'ssh -i $HOME/.ssh//vz-recover vzhost.nikopol id'; denied; }
@test "vz: -i the key by a glob"                 { run hook 'ssh -i ~/.ssh/vz* vzhost.nikopol id'; denied; }
@test "vz: -o IdentityFile naming the key"       { run hook "ssh -o 'IdentityFile ~/.ssh/./vz-recover' vzhost.nikopol id"; denied; }
@test "vz: -F an alternate config"               { run hook 'ssh -F /tmp/cfg vzhost.nikopol id'; denied; }
@test "vz: -o Include"                           { run hook "ssh -o 'Include /tmp/cfg' vzhost.nikopol id"; denied; }
@test "vz: git to a scp-like url"                { run hook 'git clone vzrecover.nikopol:repo'; denied; }
@test "vz: git to an ssh:// url"                 { run hook 'git fetch ssh://vzrecover.nikopol/x'; denied; }
@test "vz: GIT_SSH_COMMAND naming the key"       { run hook "GIT_SSH_COMMAND='ssh -i ~/.ssh/vz-recover' git fetch vzhost.nikopol:x"; denied; }
@test "vz: git -c core.sshCommand"               { run hook "git -c 'core.sshCommand=ssh -i ~/.ssh/vz-recover' fetch vzhost.nikopol:x"; denied; }
@test "vz: rsync -e naming the key"              { run hook "rsync -e 'ssh -i ~/.ssh/vz-recover' /tmp/x vzhost.nikopol:/tmp/"; denied; }
@test "ok a commit message naming the host"      { run hook "git commit -m 'deny-hook: ssh vzrecover.nikopol list only'"; allowed; }
@test "ok vz: -O check of the master"            { run hook 'ssh -O check vzrecover.nikopol'; allowed; }
@test "ok vz: -O exit of the master"             { run hook 'ssh -O exit vzrecover.nikopol'; allowed; }
@test "ok vz: -O stop of the master"             { run hook 'ssh -O stop vzrecover.nikopol'; allowed; }
@test "ok vz: -Ocheck, attached"                 { run hook 'ssh -Ocheck vzrecover.nikopol'; allowed; }
@test "vz: -O forward"                           { run hook 'ssh -O forward -L 1:localhost:1 vzrecover.nikopol'; denied; }
@test "vz: -O cancel"                            { run hook 'ssh -O cancel vzrecover.nikopol'; denied; }
@test "vz: -O exit with a remote command"        { run hook 'ssh -O exit vzrecover.nikopol id'; denied; }
@test "vz: -O exit beside another option"        { run hook 'ssh -O exit -L 1:localhost:1 vzrecover.nikopol'; denied; }
@test "ok ssh -i another key elsewhere"          { run hook 'ssh -i ~/.ssh/other nikopol-nixos.local true'; allowed; }
@test "ok the ssh public key"                   { run hook 'cat ~/.ssh/id_ed25519.pub'; allowed; }
@test "wake: ndh-claude-wake by name"             { run hook 'ndh-claude-wake --dry-run'; allowed; }
@test "wake: a local ndh-claude-wake copy"        { run hook './ndh-claude-wake'; denied; }
@test "fleet: fleet-switch by name"               { run hook 'fleet-switch --dry-run'; allowed; }
@test "fleet: fleet-switch from the system profile" { run hook '/run/current-system/sw/bin/fleet-switch'; allowed; }
@test "fleet: fleet-switch from a pushed revision" { run hook 'nix run github:seedmatic/ndh/0123abcd#fleet-switch -- --dry-run'; allowed; }
@test "fleet: a local fleet-switch copy"          { run hook './fleet-switch'; denied; }
@test "fleet: a fleet-switch under /tmp"          { run hook '/tmp/x/fleet-switch'; denied; }
@test "fleet: raw rebuilds stay denied beside it" { run hook 'fleet-switch --dry-run && sudo darwin-rebuild switch --flake github:seedmatic/ndh/0123abcd#bioskop'; denied; }

# --- the operator's Pulumi state and run logs (CAPN lab risk, 2026-10-18): the cellar's seal is no protection ---
@test "pulumi-state: a direct read"               { run hook 'cat /Volumes/git-worktree-store/seedmatic/rke2lab.d/operator/develop/.pulumi-state/.pulumi/stacks/rke2lab/dev.json'; denied; }
@test "pulumi-state: a relative read after cd"    { run hook 'cd /Volumes/git-worktree-store/seedmatic/rke2lab.d/operator/develop && cat .pulumi-state/.pulumi/meta.yaml'; denied; }
@test "pulumi-state: a count is a read too"       { run hook 'grep -c capn /Volumes/git-worktree-store/seedmatic/rke2lab.d/operator/develop/.pulumi-state/.pulumi/stacks/rke2lab/dev.json'; denied; }
@test "pulumi-state: a listing"                   { run hook 'ls /Volumes/git-worktree-store/seedmatic/rke2lab.d/operator/develop/.pulumi-state'; denied; }
@test "pulumi-state: any worktree, any depth"     { run hook 'head /tmp/w/a/b/.pulumi-state/x.json'; denied; }
@test "pulumi-state: a copy out"                  { run hook 'cp -r /Volumes/git-worktree-store/seedmatic/rke2lab.d/develop/.pulumi-state /tmp/s'; denied; }
@test "ok a name that only resembles it"          { run hook 'cat /tmp/w/.pulumi-state.md'; allowed; }
@test "ok pulumi stack ls stays free"             { run hook 'pulumi stack ls'; allowed; }
@test "local.d: the operator's run log, rke2lab"  { run hook 'tail /Volumes/git-worktree-store/seedmatic/rke2lab.d/operator/develop/.local.d/up.log'; denied; }
@test "local.d: relative, from a rke2lab worktree" { run hook 'cat .local.d/up.log' /Volumes/git-worktree-store/seedmatic/rke2lab.d/develop; denied; }
@test "ok a .local.d outside rke2lab"             { run hook 'cat /tmp/w/.local.d/notes'; allowed; }

# A glob that can expand to the state: a fake worktree under a throwaway home, so the glob meets a real directory.
mkstate() {
  W="$BATS_TEST_TMPDIR/home/seedmatic/wt"
  mkdir -p "$W/.git" "$W/.pulumi-state/.pulumi/stacks" "$W/src/deep"
  : >"$W/.pulumi-state/.pulumi/stacks/dev.json"
}
@test "pulumi-state glob: .p*, absolute"           { mkstate; HOME="$BATS_TEST_TMPDIR/home" run hook "cat $W/.p*/.pulumi/stacks/dev.json"; denied; }
@test "pulumi-state glob: .[p]ulumi-state"         { mkstate; HOME="$BATS_TEST_TMPDIR/home" run hook "cat $W/.[p]ulumi-state/.pulumi/stacks/dev.json"; denied; }
@test "pulumi-state glob: .*/.pulumi/*, relative"  { mkstate; HOME="$BATS_TEST_TMPDIR/home" run hook "cd $W && cat .*/.pulumi/stacks/dev.json"; denied; }
@test "pulumi-state glob: .pulumi-*/*"             { mkstate; HOME="$BATS_TEST_TMPDIR/home" run hook "cat $W/.pulumi-*/*"; denied; }
@test "pulumi-state glob: .p*/**/*"                { mkstate; HOME="$BATS_TEST_TMPDIR/home" run hook "cat $W/.p*/**/*"; denied; }
@test "pulumi-state glob: .[p]ulumi-state/*"       { mkstate; HOME="$BATS_TEST_TMPDIR/home" run hook "head $W/.[p]ulumi-state/*"; denied; }
@test "pulumi-state glob: .pulumi-*/ an absent x"  { mkstate; HOME="$BATS_TEST_TMPDIR/home" run hook "cat $W/.pulumi-*/x"; denied; }
@test "ok a glob that misses the state"            { mkstate; HOME="$BATS_TEST_TMPDIR/home" run hook "cat $W/src/*"; allowed; }

# --- launchers: the command a launcher runs elsewhere is judged like an ssh remote command ---
@test "launcher: tart exec of a mutating incus"       { run hook 'tart exec -i nikopol-nixos incus delete c1'; denied; }
@test "launcher: tart exec of a shell of kubectl"     { run hook 'tart exec vm sh -c "kubectl delete ns x"'; denied; }
@test "launcher: kubectl exec of a mutating helm"    { run hook 'kubectl exec -n x pod -- helm uninstall x'; denied; }
@test "launcher: kubectl exec without -- keeps its flags" { run hook 'kubectl exec pod rm -rf /Users/tester/.claude'; asked; }
@test "launcher: docker exec of a mutating helm"      { run hook 'docker exec -it -u root c1 helm uninstall x'; denied; }
@test "launcher: podman exec of a mutating pulumi"    { run hook 'podman exec c1 pulumi up --yes'; denied; }
@test "launcher: chroot of a protected read"          { run hook 'chroot /mnt cat /Users/tester/.ssh/id_ed25519'; denied; }
@test "launcher: nsenter of a mutating kubectl"      { run hook 'nsenter -t 1 -m -- kubectl delete ns x'; denied; }
@test "launcher: systemd-run of a mutating kubectl"   { run hook 'systemd-run --user -p X=1 kubectl apply -f m.yaml'; denied; }
@test "launcher: machinectl shell of a mutating incus" { run hook 'machinectl shell root@c1 /run/current-system/sw/bin/incus delete c1'; denied; }
@test "launcher: incus exec stays a gated verb"       { run hook 'incus exec c1 -- ls'; denied; }
@test "launcher: chroot with no command is a shell"   { run hook 'chroot /mnt'; asked; }
@test "launcher: machinectl shell with no command"    { run hook 'machinectl shell c1'; asked; }
@test "ok launcher: tart exec of a read-only incus"   { run hook 'tart exec incus-probe incus list'; allowed; }
@test "ok launcher: kubectl exec of a listing"        { run hook 'kubectl exec -n x pod -- ls /'; allowed; }
@test "ok launcher: docker exec of a listing"         { run hook 'docker exec c1 ls /'; allowed; }

# --- find: what -exec runs, and a removal fed by xargs ---
@test "find: -exec sh reading a protected key" {
  run hook 'find /tmp -name x -exec sh -c "cat /Users/tester/.ssh/id_ed25519" \;'
  denied
}
@test "find: -exec sh of a mutating kubectl" {
  run hook 'find /tmp/work -name m.yaml -exec sh -c "kubectl apply -f m.yaml" \;'
  denied
}
@test "ok find: -exec of a reader on a scratch tree" {
  run hook 'find /tmp/work -name "*.log" -exec wc -l {} +'
  allowed
}
@test "xargs: rm fed by find"       { run hook 'find /tmp/work -name x | xargs rm'; denied; }
@test "xargs: -0 rm -f"             { run hook 'find /tmp/work -print0 | xargs -0 rm -f'; denied; }
@test "xargs: unlink"               { run hook 'ls | xargs -n1 unlink'; denied; }
@test "xargs: mv"                   { run hook 'ls | xargs -I@ mv @ /tmp'; denied; }
@test "ok xargs: a reader"          { run hook 'ls /tmp/work | xargs wc -l'; allowed; }

# --- git under a reset environment: the session's sops-neutral config is gone ---
@test "git env reset: env -i git show"            { run hook 'env -i git show HEAD:.secrets/x.yaml'; denied; }
@test "git env reset: env - git diff"             { run hook 'env - git diff HEAD~1'; denied; }
@test "git env reset: env -u GIT_CONFIG_COUNT"    { run hook 'env -u GIT_CONFIG_COUNT git log -p -1'; denied; }
@test "git env reset: env -uGIT_CONFIG_COUNT"     { run hook 'env -uGIT_CONFIG_COUNT git blame x.yaml'; denied; }
@test "git env reset: sudo git cat-file"          { run hook 'sudo git cat-file --textconv HEAD:x.yaml'; denied; }
@test "git env reset: GIT_CONFIG_COUNT=0 prefix"  { run hook 'GIT_CONFIG_COUNT=0 git show HEAD'; denied; }
@test "git env reset: GIT_CONFIG_PARAMETERS"      { run hook "GIT_CONFIG_PARAMETERS=\"'diff.x.textconv'='sops -d'\" git show HEAD"; denied; }
@test "git env reset: unset then git diff"        { run hook 'unset GIT_CONFIG_COUNT; git diff HEAD~1'; denied; }
@test "git env reset: export then git show"       { run hook 'export GIT_CONFIG_COUNT=0 && git show HEAD'; denied; }
@test "git env reset: inherited by a nested shell" { run hook "env -i bash -c 'git show HEAD'"; denied; }
@test "git env reset: exec env -i"                { run hook 'exec env -i PATH=/usr/bin git diff'; denied; }
@test "git env reset: a push loses its pre-push hook" { run hook 'env -i git push origin memory'; denied; }
@test "git env reset: git -c of a sops textconv"  { run hook 'git -c diff.sops-yaml.textconv=sops-d show HEAD'; denied; }
@test "git env reset: exec -c"                   { run hook 'exec -c git diff HEAD~1'; denied; }
@test "git env reset: exec -cl"                  { run hook 'exec -cl git show HEAD'; denied; }
@test "git env reset: script then env -i"        { run hook 'script -q /dev/null env -i git diff HEAD~1'; denied; }
@test "git env reset: script -c of env -i"       { run hook "script -q -c 'env -i git show HEAD' /dev/null"; denied; }
@test "launcher: script of a mutating kubectl"   { run hook 'script -q /dev/null kubectl delete ns x'; denied; }
@test "git env reset: unbuffer then env -i"      { run hook 'unbuffer env -i git diff HEAD~1'; denied; }
@test "git env reset: stdbuf then env -i"        { run hook 'stdbuf -o0 env -i git diff HEAD~1'; denied; }
@test "ok exec -a of a plain git"                { run hook 'exec -a x git diff HEAD~1'; allowed; }
@test "ok script of a listing"                   { run hook 'script -q /dev/null ls'; allowed; }
@test "ok git env reset: env -i git status"       { run hook 'env -i git status'; allowed; }
@test "ok git env reset: sudo git log one line"   { run hook 'sudo git log --oneline -3'; allowed; }
@test "ok git env reset: a sibling is not reset"  { run hook 'env -i true; git show HEAD'; allowed; }
@test "ok git: bash --noprofile keeps the export" { run hook "bash --noprofile --norc -c 'git show HEAD'"; allowed; }

# --- the root's ceremony VM is the operator's, but for its smoke boot ---
@test "operator tool: ndh-ceremony-vm ceremony"   { run hook 'ndh-ceremony-vm /tmp/in /tmp/out'; denied; }
@test "operator tool: ndh-ceremony-vm bare"       { run hook 'ndh-ceremony-vm'; denied; }
@test "operator tool: ndh-ceremony-vm --smoke plus" { run hook 'ndh-ceremony-vm --smoke /tmp/out'; denied; }
@test "operator tool: ndh-ceremony-vm by store path" { run hook '/nix/store/abc-ndh-ceremony-vm/bin/ndh-ceremony-vm /tmp/in /tmp/out'; denied; }
@test "ok ndh-ceremony-vm --smoke"                { run hook 'ndh-ceremony-vm --smoke'; allowed; }

# --- the LLM gateway relay: its key, its port beyond /v1, its unit ---
@test "relay: reading its key"                 { run hook 'cat /var/lib/loopback-forward/vzhost-4001/id_ed25519'; denied; }
@test "relay: reading its key over ssh"        { run hook 'ssh nixos.nikopol sudo cat /var/lib/loopback-forward/vzhost-4001/id_ed25519'; denied; }
@test "relay: copying its state"               { run hook 'cp -r /var/lib/loopback-forward /tmp/x'; denied; }
@test "relay: the agent's pages by name"       { run hook 'curl -s http://nixos.nikopol:4001/_aikey/'; denied; }
@test "relay: the root path by address"        { run hook 'curl -s 172.16.16.1:4001/'; denied; }
@test "relay: stopping its unit over ssh"      { run hook 'ssh nixos.nikopol sudo systemctl stop loopback-forward-vzhost-4001'; asked; }
@test "relay: restarting its unit"             { run hook 'systemctl restart loopback-forward-vzhost-4001.service'; asked; }
@test "relay: masking its unit"                { run hook 'systemctl mask loopback-forward-vzhost-4001'; asked; }
@test "relay: killing its ssh"                 { run hook 'pkill -f loopback-forward'; asked; }
@test "relay: the ask names the relay"         { run hook 'systemctl stop loopback-forward-vzhost-4001'; [[ "$output" == *"LLM gateway relay"* ]]; }
@test "ok relay: its unit's status"            { run hook 'systemctl status loopback-forward-vzhost-4001'; allowed; }
@test "ok relay: its journal"                  { run hook 'journalctl -u loopback-forward-vzhost-4001 -n 20'; allowed; }
@test "relay: a dot segment out of /v1"       { run hook 'curl http://nixos.nikopol:4001/v1/../_aikey/'; denied; }
@test "relay: an encoded dot segment"          { run hook 'curl http://nixos.nikopol:4001/v1/%2E%2E/_aikey/'; denied; }
@test "relay: the host in capitals"            { run hook 'curl http://NIXOS.NIKOPOL:4001/_aikey/'; denied; }
@test "relay: the address as one number"       { run hook 'curl http://2886733825:4001/_aikey/'; denied; }
@test "relay: through the session's base url"  { run hook 'curl "$ANTHROPIC_BASE_URL/_aikey/"'; denied; }
@test "relay: the base url in braces"          { run hook 'curl "${ANTHROPIC_BASE_URL}/v1/../_aikey/"'; denied; }
@test "relay: curl's request target"           { run hook 'curl --request-target /_aikey/ http://nixos.nikopol:4001'; denied; }
@test "ok relay: /v1 through the base url"     { run hook 'curl "$ANTHROPIC_BASE_URL/v1/messages" -d @req.json'; allowed; }
@test "ok relay: request target in /v1"        { run hook 'curl --request-target /v1/models http://nixos.nikopol:4001'; allowed; }
@test "ok relay: the /v1 API"                  { run hook 'curl -s http://nixos.nikopol:4001/v1/models'; allowed; }
@test "ok relay: the base url in a grep"       { run hook 'git grep -n nixos.nikopol:4001 -- modules'; allowed; }
@test "seed run: the ask keeps its own reason" { run hook 'mvn exec:java -pl :seed-outcluster'; [[ "$output" == *"live/preview mode"* ]]; }

# --- VS Code's state stores: the Flox extension froze whole environments there, tokens included ---
@test "vscode: reading a workspace's state db"   { run hook 'sqlite3 -readonly "/Users/tester/Library/Application Support/Code/User/workspaceStorage/abc123/state.vscdb" .dump'; denied; }
@test "vscode: its backup"                       { run hook 'strings "/Users/tester/Library/Application Support/Code/User/workspaceStorage/abc123/state.vscdb.backup"'; denied; }
@test "vscode: an Insiders workspace db"         { run hook 'cat ~/Library/Application\ Support/Code\ -\ Insiders/User/workspaceStorage/x/state.vscdb'; denied; }
@test "vscode: the global state db"              { run hook 'cp "/Users/tester/Library/Application Support/Code/User/globalStorage/state.vscdb" /tmp/x'; denied; }
@test "vscode: a glob over the workspaces" {
  # A glob is judged by what it expands to: a real home holding one workspace's db.
  HOME="$BATS_TEST_TMPDIR/h"
  mkdir -p "$HOME/Library/Application Support/Code/User/workspaceStorage/w1"
  touch "$HOME/Library/Application Support/Code/User/workspaceStorage/w1/state.vscdb"
  run hook 'sqlite3 ~/Library/Application\ Support/Code/User/workspaceStorage/*/state.vscdb .tables'
  denied
}
@test "ok vscode: the workspace.json beside it"  { run hook 'cat "/Users/tester/Library/Application Support/Code/User/workspaceStorage/abc123/workspace.json"'; allowed; }
@test "ok vscode: the user settings"             { run hook 'cat "/Users/tester/Library/Application Support/Code/User/settings.json"'; allowed; }

# --- pass-seedmatic-publish signs with the operator's key: theirs alone ---
@test "operator tool: pass-seedmatic-publish"          { run hook 'pass-seedmatic-publish'; denied; }
@test "operator tool: pass-seedmatic-publish dry run"  { run hook 'pass-seedmatic-publish --dry-run'; denied; }
@test "operator tool: pass-seedmatic-publish by nix"   { run hook 'nix run "git+file:///Volumes/git-bare-store/nxmatic/claude-home.git?ref=claude/develop#pass-seedmatic-publish"'; denied; }
