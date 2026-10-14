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
