# content-guard — refuse what carries a secret's shape before it leaves a metalspace (the copy to the
# corporate vz-host, a future check before an attic upload; docs/private-binary-cache-spec.adoc). It
# judges content, never names, and prints only the paths it refuses, never what it matched.
#
# The shapes: rke2lab's token_shape_guard (an age secret, a JWT, tailscale, GitHub, Docker and GitLab
# tokens), AWS's (an access key id, a secret or session key with its value: the sessions reach Bedrock
# through an AWS profile on these machines), a nix signing secret (`<name>:` and 64 bytes in base64;
# a public is 32), a private-key armour followed by a body, and a sops
# annotation followed by anything but an ENC[ value.
# Usage: content-guard <path>... — exit 0 when every path is clean, 1 when one carries a shape.
[ "$#" -gt 0 ] || {
  echo "usage: content-guard <path>..." >&2
  exit 2
}

shaped() { # <path> → exit 0 when the path (a file or a tree) carries a secret's shape
  LC_ALL=C grep -a -r -l -q -E \
    'AGE-SECRET-KEY-1[A-Z0-9]{50,}|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|tskey-[A-Za-z0-9-]{16,}|gh[opsu]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|dckr_pat_[A-Za-z0-9_-]{20,}|glpat-[A-Za-z0-9_-]{20,}|(^|[^A-Z0-9])(AKIA|ASIA)[A-Z0-9]{16}([^A-Z0-9]|$)|aws_(secret_access_key|session_token)["'\'']?[[:space:]]*[=:][[:space:]]*["'\'']?[A-Za-z0-9/+=]{20,}|[A-Za-z0-9._-]+:[A-Za-z0-9+/]{86}==' \
    "$1" && return 0
  # shellcheck disable=SC2016 # awk's $0, intentionally single-quoted
  LC_ALL=C find "$1" -type f -print0 | xargs -0 -r awk '
    FNR == 1 { prev = "" }
    prev ~ /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/ && $0 ~ /^[A-Za-z0-9+\/=]{40,}$/ { print "HIT"; exit }
    prev ~ /# sops:encrypted/ && $0 !~ /ENC\[/ { print "HIT"; exit }
    { prev = $0 }' 2>/dev/null | grep -q HIT
}

status=0
for path in "$@"; do
  [ -e "$path" ] || {
    echo "content-guard: no such path: $path" >&2
    exit 2
  }
  if shaped "$path"; then
    printf 'refused %s\n' "$path"
    status=1
  fi
done
exit "$status"
