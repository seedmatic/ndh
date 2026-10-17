#!/usr/bin/env bats
# Feeds PreToolUse JSON to deny-hook.py. Nothing here runs the commands under test.

setup() {
  HOOK="$BATS_TEST_DIRNAME/../deny-hook.py"
  REPO=/Volumes/git-worktree-store/seedmatic/rke2lab.d/develop
  export HOME=/Users/tester
}

hook() {
  jq -n --arg c "$1" --arg cwd "${2:-/tmp/work}" \
    '{hook_event_name:"PreToolUse", permission_mode:"bypassPermissions",
      tool_name:"Bash", tool_input:{command:$c}, cwd:$cwd}' | python3 "$HOOK"
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
@test "operator tool: ndh-identity-push" { run hook 'ndh-identity-push --dry-run'; denied; }
@test "operator tool: by its store path" { run hook '/nix/store/abc-ssh-keys-renew/bin/ssh-keys-renew --revoke-host x'; denied; }
@test "operator tool: nix run of a pushed revision" { run hook 'nix run github:seedmatic/ndh/0123abcd#ssh-keys-certify -- --apply'; denied; }
@test "operator tool: nix run by revision of the bare" { run hook 'nix run "git+file:///Volumes/git-bare-store/seedmatic/ndh.git?rev=0123abcd#attic-leaf-sign"'; denied; }
@test "operator tool: inside a bash -c" { run hook "bash -c 'ndh-keyring status'"; denied; }
@test "operator tool: through flox and sudo" { run hook 'flox activate -- sudo incus-cluster-cert-renew'; denied; }
@test "operator tool: over ssh" { run hook 'ssh darwin.nikopol ndh-identity-push'; denied; }
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
@test "ok the ssh public key"                   { run hook 'cat ~/.ssh/id_ed25519.pub'; allowed; }
@test "wake: ndh-claude-wake by name"             { run hook 'ndh-claude-wake --dry-run'; allowed; }
@test "wake: a local ndh-claude-wake copy"        { run hook './ndh-claude-wake'; denied; }
@test "fleet: fleet-switch by name"               { run hook 'fleet-switch --dry-run'; allowed; }
@test "fleet: fleet-switch from the system profile" { run hook '/run/current-system/sw/bin/fleet-switch'; allowed; }
@test "fleet: fleet-switch from a pushed revision" { run hook 'nix run github:seedmatic/ndh/0123abcd#fleet-switch -- --dry-run'; allowed; }
@test "fleet: a local fleet-switch copy"          { run hook './fleet-switch'; denied; }
@test "fleet: a fleet-switch under /tmp"          { run hook '/tmp/x/fleet-switch'; denied; }
@test "fleet: raw rebuilds stay denied beside it" { run hook 'fleet-switch --dry-run && sudo darwin-rebuild switch --flake github:seedmatic/ndh/0123abcd#bioskop'; denied; }
@test "publish: cache-publish --apply"            { run hook 'cache-publish --apply github:seedmatic/ndh/0123abcd'; denied; }
@test "publish: behind sudo -u _ndh-publish -H"   { run hook 'sudo -u _ndh-publish -H cache-publish --apply github:seedmatic/ndh/0123abcd'; denied; }
@test "publish: by its store path"                { run hook '/nix/store/abc-cache-publish/bin/cache-publish --apply x'; denied; }
@test "publish: nix run of a pushed revision"     { run hook 'nix run github:seedmatic/ndh/0123abcd#cache-publish -- --apply github:seedmatic/ndh/0123abcd'; denied; }
@test "publish: inside a bash -c"                 { run hook "bash -c 'cache-publish --apply x'"; denied; }
@test "publish: the --apply=… form"               { run hook 'cache-publish --apply=1 x'; denied; }
@test "ok cache-publish dry run"                  { run hook 'sudo -u _ndh-publish -H cache-publish "git+file:///Volumes/git-bare-store/seedmatic/ndh.git?rev=0123abcd"'; allowed; }
@test "ok cache-publish through an armed ndh-ops" { run hook 'nix run github:seedmatic/ndh/0123abcd#ndh-ops -- cache-publish --apply github:seedmatic/ndh/0123abcd'; allowed; }
