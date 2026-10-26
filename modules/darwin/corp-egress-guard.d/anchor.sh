# corp-egress-anchor — the seat sends nothing to the corporate bare-metal but the operator's ssh.
#
#   corp-egress-anchor <v4 rules file> <v6 secret> <anchor file> <pfctl> <anchor name>
#
# The v4 rules are rendered from the catalog; the v6 ones are built here from a sops secret, so the home's /64 and
# the host's link-local addresses never enter the store. The secret is three lines: `home_prefix <cidr>`, the home
# /64; `router <addr>`, the router's global address in it, kept reachable so the seat's own v6 still leaves the house;
# and `link_local <addr>…`, the host's stable fe80 addresses. The rest of fe80::/10 stays open: Continuity rides it to
# the operator's own devices.
#
# Fails closed: a missing, empty or malformed secret loads nothing and exits non-zero, so the activation is loud, and
# pf keeps the anchor it had. The file is written root 0600 and loaded, then read back: an anchor pf did not take
# is a failure, not a warning.

v4="${1:?usage: corp-egress-anchor <v4 rules> <v6 secret> <anchor file> <pfctl> <anchor name>}"
secret="${2:?usage: corp-egress-anchor <v4 rules> <v6 secret> <anchor file> <pfctl> <anchor name>}"
anchor_file="${3:?usage: corp-egress-anchor <v4 rules> <v6 secret> <anchor file> <pfctl> <anchor name>}"
# Named by the caller, never looked up: this runs as root at activation.
pfctl="${4:?usage: corp-egress-anchor <v4 rules> <v6 secret> <anchor file> <pfctl> <anchor name>}"
anchor="${5:?usage: corp-egress-anchor <v4 rules> <v6 secret> <anchor file> <pfctl> <anchor name>}"

die() {
  echo "[corp-egress-anchor] ERROR: $*: nothing loaded" >&2
  exit 1
}

[[ -s $v4 ]] || die "the v4 rules $v4 are missing or empty"
[[ -f $secret && ! -L $secret && -s $secret ]] || die "the v6 secret is missing or empty"

prefix=$(awk '$1 == "home_prefix" { print $2 }' "$secret")
router=$(awk '$1 == "router" { print $2 }' "$secret")
read -ra link_local <<<"$(awk '$1 == "link_local" { $1 = ""; print }' "$secret")"
[[ $prefix =~ ^[0-9a-fA-F:]+::/64$ ]] || die "home_prefix is not a /64"
[[ $router =~ ^[0-9a-fA-F:]+$ && $router == "${prefix%%::/64}:"* ]] || die "router is not an address inside home_prefix"
((${#link_local[@]} > 0)) || die "no link_local address"
for a in "${link_local[@]}"; do
  [[ $a =~ ^[fF][eE]80:[0-9a-fA-F:]+$ ]] || die "a link_local entry is not an fe80 address"
done

tmp=$(mktemp "$(dirname "$anchor_file")/.corp-egress.XXXXXX")
trap 'rm -f "$tmp"' EXIT
chmod 0600 "$tmp"
{
  cat "$v4"
  echo "pass out quick inet6 to $router"
  echo "block out quick log inet6 to $prefix"
  for a in "${link_local[@]}"; do echo "block out quick log inet6 to $a"; done
} >"$tmp"

"$pfctl" -a "$anchor" -n -f "$tmp" || die "pfctl refuses the rules"
mv "$tmp" "$anchor_file"
trap - EXIT
"$pfctl" -a "$anchor" -f "$anchor_file" || die "pfctl did not load the anchor"
# Read back and compared with what was written, line for line, never counted: a count accepts a dropped rule
# replaced by another, or a pass widened in place. Two blocks for v4, one for the /64, one per link-local address.
expected=$((2 + 1 + ${#link_local[@]}))
held=$("$pfctl" -a "$anchor" -s rules 2>/dev/null || true)
loaded=$(grep -c '^block' <<<"$held" || true)
((loaded == expected)) || die "the anchor holds $loaded block rules after loading, not $expected"
[[ $held == "$(cat "$anchor_file")" ]] || die "the anchor pf holds is not the one written"
# pfctl reports what the anchor holds, whether pf filters or not: say which, so the line is not read as protection.
if "$pfctl" -s info 2>/dev/null | grep -q '^Status: Enabled'; then state="pf is enabled: filtering"; else state="pf is disabled: not filtering"; fi
echo "[corp-egress-anchor] $anchor loaded, $loaded block rules; $state"
