#!@bashBin@
set -euxo pipefail

preferred_dns="@preferredDnsString@"

services_list=()
while IFS= read -r svc; do
  [ -n "$svc" ] || continue
  services_list+=("$svc")
done < <(networksetup -listallnetworkservices | sed '1d;s/^\*//')

service_exists() {
  local target="$1"
  local entry
  for entry in "${services_list[@]}"; do
    if [ "$entry" = "$target" ]; then
      return 0
    fi
  done
  return 1
}

ordered_services=()
append_service() {
  local svc="$1"
  local existing
  for existing in "${ordered_services[@]}"; do
    if [ "$existing" = "$svc" ]; then
      return
    fi
  done
  ordered_services+=("$svc")
}

preferred_services=( @preferredServicesLiteral@ )

for iface in "${preferred_services[@]}"; do
  if service_exists "$iface"; then
    append_service "$iface"
  else
    echo "Preferred service $iface not present; skipping ordering preference"
  fi
done

for svc in "${services_list[@]}"; do
  append_service "$svc"
done

if [ "${#ordered_services[@]}" -gt 0 ]; then
  if networksetup -ordernetworkservices "${ordered_services[@]}" >/dev/null 2>&1; then
    echo "Applied service order: ${ordered_services[*]}"
  else
    echo "Warning: networksetup -ordernetworkservices failed"
  fi
fi

get_device_for_service() {
  local service="$1"
  networksetup -listallhardwareports | awk -v svc="$service" '
    $0 ~ "^Hardware Port: " svc "$" {
      getline
      if ($0 ~ /^Device: /) {
        sub(/^Device: /, "", $0)
        print $0
        exit
      }
    }
  '
}

get_dhcp_dns_servers() {
  local device="$1"
  if [ -z "$device" ]; then
    return
  fi
  ipconfig getpacket "$device" 2>/dev/null | awk '
    /domain_name_server/ {
      sub(/.*: */, "", $0)
      gsub(/[{}]/, "", $0)
      gsub(/,/, " ", $0)
      gsub(/  +/, " ", $0)
      printf "%s ", $0
    }
  ' | awk 'NF { $1=$1; print }'
}

for iface in "${preferred_services[@]}"; do
  if ! service_exists "$iface"; then
    continue
  fi
  echo "Configuring DNS for interface: $iface"
  device="$(get_device_for_service "$iface")"
  if [ -z "$device" ]; then
    echo "No hardware device found for $iface, skipping"
    continue
  fi
  dhcp_servers="$(get_dhcp_dns_servers "$device")"
  combined=""
  for srv in $preferred_dns $dhcp_servers; do
    [ -n "$srv" ] || continue
    case " $combined " in
      *" $srv "*) ;;
      *) combined="$combined $srv" ;;
    esac
  done
  combined="$(printf '%s\n' "$combined" | awk 'NF { $1=$1; print }')"
  if [ -n "$combined" ]; then
    IFS=' ' read -r -a dns_array <<<"$combined"
    if networksetup -setdnsservers "$iface" "${dns_array[@]}" >/dev/null 2>&1; then
      echo "Set DNS for $iface -> $combined"
    else
      echo "Warning: failed to set DNS servers for $iface"
    fi
  else
    echo "No DNS servers determined for $iface"
  fi
done
