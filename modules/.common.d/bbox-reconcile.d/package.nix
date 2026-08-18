# `bbox-reconcile` — diff the LAN catalog against the bbox's
# `/api/v1/dhcp/clients` table and report drift.
#
# Exposed as the `bbox-reconcile` flake app (`nix run .#bbox-reconcile`), not
# baked into every host's system packages — it is an operator entrypoint, so it
# lives behind the flake's app surface like the other `nix run .#…` commands.
#
# Read-only.  The bbox API surfaces a write path on the same endpoint
# (POST/PUT/DELETE on `/dhcp/clients/<id>`) but we have not yet captured the
# body shape the UI sends, so this is diff-only until that's settled.  See
# `docs/bbox-api.adoc` for the full surface and probing convention.
#
# Inputs
#   - `catalog.netplan.lan.hosts`   — declared static reservations
#   - `catalog.netplan.lan.routers.mammoth-skate.adminUrl` — bbox UI base URL
#   - `.secrets` `lan.mammoth-skate.password`              — bbox admin password
#
# Comparison key is MAC address (the only identifier the bbox treats as
# primary).  Hostname or IP changes against the same MAC count as drift, not as
# missing/extra.
{
  pkgs,
  lib,
  catalog,
  worktreePath,
}:
let
  netplan = catalog.netplan or { };
  lan = netplan.lan or { };
  hosts = lan.hosts or { };
  router = lib.attrByPath [ "routers" "mammoth-skate" ] null lan;

  # Materialise the catalog hosts as JSON in the Nix store so the
  # script reads it without re-evaluating Nix at runtime.
  hostsJson = pkgs.writeText "bbox-reconcile-lan-hosts.json" (builtins.toJSON hosts);

  # The ignore list lives in the source tree as a plain YAML so
  # operators can edit it with normal text-editing tools and the
  # `note` field documents why a MAC is being silenced.  Surfaced
  # here as a JSON array of lowercased MACs the runtime script
  # consumes directly.
  ignoredYaml = (worktreePath.of "catalog/lan-ignored-reservations.yaml");
  ignoredJson =
    pkgs.runCommand "bbox-reconcile-ignored.json"
      {
        buildInputs = [ pkgs.yq-go ];
      }
      ''
        yq -p=yaml -o=json '[.ignored_reservations[].mac | downcase]' \
          ${ignoredYaml} > "$out"
      '';

  routerAdminUrl = if router != null then router.adminUrl else "";
in
pkgs.writeShellApplication {
  name = "bbox-reconcile";
  runtimeInputs = with pkgs; [
    coreutils
    curl
    sops
    yq-go
  ];
  text = ''
    set -euo pipefail

    ROUTER_URL='${routerAdminUrl}'
    HOSTS_JSON='${hostsJson}'
    IGNORED_JSON='${ignoredJson}'
    SECRETS_FILE='${worktreePath.of ".secrets"}'

    usage() {
      cat >&2 <<'EOF'
    usage: bbox-reconcile [diff]

    Compare catalog.netplan.lan.hosts against the bbox's
    /api/v1/dhcp/clients reservation table.  Read-only.

      diff   (default) print missing / extra / drift by MAC
      -h, --help

    Exit code:
      0  catalog matches bbox
      1  drift detected
      2  usage error
      >2 internal failure (auth, network, parse)
    EOF
    }

    mode="''${1:-diff}"
    case "$mode" in
      diff) ;;
      -h|--help|help) usage; exit 0 ;;
      *) usage; exit 2 ;;
    esac

    if [[ -z "$ROUTER_URL" ]]; then
      echo "[bbox-reconcile][ERROR] catalog.netplan.lan.routers.mammoth-skate.adminUrl is unset" >&2
      exit 3
    fi

    # --- read bbox admin password from sops ---
    password="$(sops -d --extract '["lan"]["mammoth-skate"]["password"]' \
      --input-type yaml --output-type yaml "$SECRETS_FILE" 2>/dev/null \
      | tr -d '\n' || true)"
    if [[ -z "$password" ]]; then
      echo "[bbox-reconcile][ERROR] failed to extract lan.mammoth-skate.password from $SECRETS_FILE" >&2
      echo "[bbox-reconcile][HINT] check SOPS_AGE_KEY_FILE / ~/.config/sops/age/keys.txt" >&2
      exit 3
    fi

    # --- authenticate against the bbox ---
    cookie="$(mktemp -t bbox-jar.XXXXXX)"
    chmod 600 "$cookie"
    trap 'rm -f "$cookie"' EXIT INT TERM

    login_status="$(curl -sS -c "$cookie" -k \
      --data-urlencode "password=$password" \
      -o /dev/null -w '%{http_code}' \
      "$ROUTER_URL/api/v1/login")"
    if [[ "$login_status" != "200" ]]; then
      echo "[bbox-reconcile][ERROR] $ROUTER_URL/api/v1/login returned HTTP $login_status" >&2
      exit 4
    fi

    # --- normalise both sources to a single YAML doc keyed by MAC.
    #     One yq pipeline merges them and computes the diff entirely
    #     within yq, so the bash side just consumes a final report
    #     without needing awk/jq for column splits.
    tmp="$(mktemp -d)"
    trap 'rm -f "$cookie"; rm -rf "$tmp"' EXIT INT TERM
    bbox_yaml="$tmp/bbox.yaml"
    catalog_yaml="$tmp/catalog.yaml"
    report_yaml="$tmp/report.yaml"

    # bbox: array of {hostname, mac, ip}, with ignored MACs filtered
    # out so they never appear as EXTRA.  Lowercase comparison
    # because the bbox UI lets operators enter MACs in any case.
    curl -sS -b "$cookie" -k "$ROUTER_URL/api/v1/dhcp/clients" \
      | yq -p=json -o=yaml \
          '[.[0].dhcp.clients[] | {"hostname": .hostname, "mac": .macaddress, "ip": .ipaddress}]' \
      > "$tmp/bbox-raw.yaml"

    # shellcheck disable=SC2016 # yq operator $ignore intentionally single-quoted
    ignored_count="$(yq -p=yaml -o=yaml '
      load("'"$IGNORED_JSON"'") as $ignore |
      [.[] | select(.mac | downcase | (. as $m | $ignore | contains([$m])))] | length
    ' "$tmp/bbox-raw.yaml")"

    # shellcheck disable=SC2016 # yq operator $ignore intentionally single-quoted
    yq -p=yaml -o=yaml '
      load("'"$IGNORED_JSON"'") as $ignore |
      [.[] | select(.mac | downcase | (. as $m | $ignore | contains([$m])) | not)]
    ' "$tmp/bbox-raw.yaml" > "$bbox_yaml"

    # catalog: array of {hostname, mac, ip, kind}
    yq -p=json -o=yaml \
      '[to_entries | .[] | {"hostname": .key, "mac": .value.mac, "ip": .value.ip, "kind": .value.kind}]' \
      "$HOSTS_JSON" > "$catalog_yaml"

    # Build a single report:
    #   - keyed by mac
    #   - each entry carries .catalog and/or .bbox sub-fields
    #   - downstream classifies missing / extra / drift by which side is set
    # shellcheck disable=SC2016 # yq operators ($b/$c) intentionally single-quoted
    yq eval-all '
      (select(fileIndex == 0) | [.[] | {(.mac): {"bbox":    .}}] | .[] as $i ireduce ({}; . * $i)) as $b |
      (select(fileIndex == 1) | [.[] | {(.mac): {"catalog": .}}] | .[] as $i ireduce ({}; . * $i)) as $c |
      $b * $c
    ' "$bbox_yaml" "$catalog_yaml" > "$report_yaml"

    # Bucket counts straight from the report
    missing_count="$(yq '[to_entries[] | select(.value.catalog and (.value.bbox == null))] | length' "$report_yaml")"
    extra_count="$(yq   '[to_entries[] | select(.value.bbox    and (.value.catalog == null))] | length' "$report_yaml")"
    drift_count="$(yq   '[to_entries[] | select(.value.catalog and .value.bbox and ((.value.catalog.hostname != .value.bbox.hostname) or (.value.catalog.ip != .value.bbox.ip)))] | length' "$report_yaml")"
    catalog_total="$(yq 'length' "$catalog_yaml")"
    bbox_total="$(yq    'length' "$bbox_yaml")"

    echo "=== bbox-reconcile diff ==="
    echo "Catalog hosts:           $catalog_total"
    echo "Bbox /dhcp/clients:      $bbox_total (+ $ignored_count ignored)"
    echo

    if [[ "$missing_count" -gt 0 ]]; then
      echo "MISSING (in catalog, not on bbox):"
      yq -r '
        to_entries[]
        | select(.value.catalog and (.value.bbox == null))
        | "  \(.value.catalog.hostname) [\(.value.catalog.mac)] \(.value.catalog.ip) (kind=\(.value.catalog.kind))"
      ' "$report_yaml"
      echo
    fi

    if [[ "$extra_count" -gt 0 ]]; then
      echo "EXTRA (on bbox, not in catalog):"
      yq -r '
        to_entries[]
        | select(.value.bbox and (.value.catalog == null))
        | "  \(.value.bbox.hostname) [\(.value.bbox.mac)] \(.value.bbox.ip)"
      ' "$report_yaml"
      echo
    fi

    if [[ "$drift_count" -gt 0 ]]; then
      echo "DRIFT (mac present in both, hostname or ip differs):"
      yq -r '
        to_entries[]
        | select(.value.catalog and .value.bbox)
        | select((.value.catalog.hostname != .value.bbox.hostname) or (.value.catalog.ip != .value.bbox.ip))
        | "  \(.key): catalog=\(.value.catalog.hostname)/\(.value.catalog.ip) bbox=\(.value.bbox.hostname)/\(.value.bbox.ip)"
      ' "$report_yaml"
      echo
    fi

    if [[ "$missing_count" -eq 0 && "$extra_count" -eq 0 && "$drift_count" -eq 0 ]]; then
      echo "All catalog hosts match bbox /dhcp/clients reservations."
      exit 0
    fi

    echo "Drift detected ($missing_count missing, $extra_count extra, $drift_count modified)."
    exit 1
  '';
}
