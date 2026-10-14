# Every line of a host's rendered postActivation that reads a sops secret must come AFTER sops-nix
# installs them ("Setting up secrets…"). A reader placed earlier reads the previous generation, so a
# rotated secret was picked up one activation late — the compose, the ssh-keys enrichment and the
# user secret mirror all did, each believing the install ran at mkOrder 1000.
{
  pkgs,
  # system.activationScripts.postActivation.text of the host under test
  text,
  name,
}:
pkgs.runCommand "secrets-read-after-install-${name}" { } ''
  script=${pkgs.writeText "postActivation-${name}" text}
  marker="$(grep -n 'Setting up secrets' "$script" | head -1 | cut -d: -f1)"
  if [ -z "$marker" ]; then
    echo "FAIL ${name}: no 'Setting up secrets' marker in postActivation" >&2
    exit 1
  fi
  early="$(head -n "$((marker - 1))" "$script" | grep -n '/run/secrets' || true)"
  # A reader can hide the path in a script it calls (the compose did): look one level down, in every
  # store file the early lines execute or pass.
  while IFS= read -r called; do
    if [ -f "$called" ] && grep -q '/run/secrets' "$called"; then
      early="$early''${early:+$'\n'}calls $called, which reads /run/secrets"
    fi
  done < <(head -n "$((marker - 1))" "$script" | grep -o '/nix/store/[a-z0-9]\{32\}-[^ "'"'"';]*' | sort -u)
  if [ -n "$early" ]; then
    echo "FAIL ${name}: these postActivation lines read a secret before sops-nix installs them (line $marker):" >&2
    printf '%s\n' "$early" | cut -c1-200 >&2
    exit 1
  fi
  echo "ok   ${name}: no secret is read before line $marker"
  touch $out
''
