# viewer-kubeconfig: the sessions' read-only kubeconfig, collected from the operator's (an ndh-ops tool they arm).
#   viewer-kubeconfig [--admin <kubeconfig>] [--out <file>]
# For each context of the admin kubeconfig, it reads the token of kube-system/rke2lab-session-viewer (rke2lab's
# cluster/session-viewer unit: reads, no Secrets, no log/exec/attach/portforward/proxy) with that cluster's server, and
# writes one `<context>-viewer` context per cluster. The admin kubeconfig is only READ; the file is written 0600, whole
# or not at all. It never sets KUBECONFIG: sessions name the file each time with --kubeconfig.
set -euo pipefail

admin="${HOME}/.kube/config"
out="${HOME}/.kube/viewer"
account=rke2lab-session-viewer
namespace=kube-system

while (($#)); do
  case $1 in
    --admin)
      admin=${2:?--admin needs a file}
      shift
      ;;
    --out)
      out=${2:?--out needs a file}
      shift
      ;;
    *)
      echo "viewer-kubeconfig: unknown argument $1" >&2
      exit 2
      ;;
  esac
  shift
done

[[ -r $admin ]] || {
  echo "viewer-kubeconfig: cannot read $admin" >&2
  exit 1
}
if [[ $(realpath -m "$out") == "$(realpath -m "$admin")" ]]; then
  echo "viewer-kubeconfig: refusing to write over the admin kubeconfig $admin" >&2
  exit 1
fi

view=$(kubectl --kubeconfig "$admin" config view --raw -o json) || {
  echo "viewer-kubeconfig: cannot read the contexts of $admin" >&2
  exit 1
}
contexts=$(jq -r '.contexts[]?.name' <<<"$view")
[[ -n $contexts ]] || {
  echo "viewer-kubeconfig: $admin has no context" >&2
  exit 1
}

entries='[]'
skipped=()
while IFS= read -r context; do
  server=$(jq -r --arg c "$context" \
    '(.contexts[] | select(.name == $c) | .context.cluster) as $k | .clusters[] | select(.name == $k) | .cluster.server' \
    <<<"$view")
  if ! secret=$(kubectl --kubeconfig "$admin" --context "$context" --request-timeout=10s \
    -n "$namespace" get secret "$account-token" -o json); then
    skipped+=("$context: no $namespace/$account-token")
    continue
  fi
  token=$(jq -r '.data.token // empty' <<<"$secret")
  ca=$(jq -r '.data["ca.crt"] // empty' <<<"$secret")
  if [[ -z $token || -z $ca || -z $server ]]; then
    skipped+=("$context: token not issued yet")
    continue
  fi
  entries=$(jq --arg n "$context-viewer" --arg s "$server" --arg ca "$ca" --arg t "$(base64 -d <<<"$token")" \
    '. + [{name: $n, server: $s, ca: $ca, token: $t}]' <<<"$entries")
done <<<"$contexts"

for s in "${skipped[@]}"; do echo "viewer-kubeconfig: skipped $s" >&2; done
written=$(jq length <<<"$entries")
((written > 0)) || {
  echo "viewer-kubeconfig: no cluster answered with a viewer token" >&2
  exit 1
}

umask 077
mkdir -p "$(dirname "$out")"
tmp=$(mktemp "$out.XXXXXX")
trap 'rm -f "$tmp"' EXIT
jq '{apiVersion: "v1", kind: "Config",
     clusters: map({name, cluster: {server, "certificate-authority-data": .ca}}),
     contexts: map({name, context: {cluster: .name, user: .name}}),
     users: map({name, user: {token}})}' <<<"$entries" >"$tmp"
chmod 0600 "$tmp"
mv -f "$tmp" "$out"
trap - EXIT
echo "viewer-kubeconfig: $written context(s) in $out (0600); use it with --kubeconfig $out"
