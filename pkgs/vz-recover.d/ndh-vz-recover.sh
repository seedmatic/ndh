# ndh-vz-recover: the forced command of the vz-recover key on a foreign vz-host, a closed vocabulary over the
# Tart VMs of its metalspace. The header sets probeMarker, vms, kinds (nixos|darwin, by index), tart, timeout
# and open.
#
#   probe                  prints probeMarker alone: a caller that reads anything else (a shell's output, a
#                          login banner, an error) knows the forced command is not in force, and stops
#   list                   each VM: its guest agent answers or not
#   restart <vm>           tart stop, then the VM's launcher in a new Terminal window, as the operator runs it
#   rollback <vm>          in the guest: back to the previous system generation
#   restart-access <vm>    in the guest: tailscaled, and sshd on NixOS (darwin's sshd is socket-activated)
#
# The client's words arrive in SSH_ORIGINAL_COMMAND and are matched, never evaluated: anything else is
# refused with 64. One call at a time (75 when busy); every call, refusals included, is one log line without
# its output. `tart exec` passes every word after the guest executable through, and takes `--` for the
# executable itself (tart 2.36), so the guest argv starts with the executable. `tart list` is not used: it
# fails while a VM runs (its disk image is locked for `diskutil image info`).

raw=${SSH_ORIGINAL_COMMAND-}
client=${SSH_CLIENT-}
client=${client%% *}
logFile=$HOME/Library/Logs/ndh-vz-recover.log
lockDir=$HOME/.local/state/ndh-vz-recover/lock

record() {
  mkdir -p "${logFile%/*}"
  (
    umask 077
    printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${client:--}" "$*" >>"$logFile"
  )
}

refuse() {
  record "refused 64 $(printf '%s' "${raw:0:80}" | LC_ALL=C tr -c '[:print:]' '?')"
  echo "ndh-vz-recover: refused; usage: probe | list | restart <vm> | rollback <vm> | restart-access <vm>" >&2
  exit 64
}

[[ $raw =~ ^(probe|list|restart|rollback|restart-access)( ([a-z0-9-]+))?$ ]] || refuse
verb=${BASH_REMATCH[1]}
vm=${BASH_REMATCH[3]}

if [[ $verb == probe ]]; then
  [[ -z $vm ]] || refuse
  printf '%s\n' "$probeMarker"
  record "probe - 0"
  exit 0
fi

if [[ $verb == list ]]; then
  [[ -z $vm ]] || refuse
  for i in "${!vms[@]}"; do
    if [[ ${kinds[i]} == nixos ]]; then probe=/run/current-system/sw/bin/true; else probe=/usr/bin/true; fi
    if "$timeout" 10 "$tart" exec "${vms[i]}" "$probe" >/dev/null 2>&1; then
      echo "${vms[i]} agent-up"
    else
      echo "${vms[i]} no-agent"
    fi
  done
  record "list - 0"
  exit 0
fi

kind=""
for i in "${!vms[@]}"; do
  [[ ${vms[i]} != "$vm" ]] || kind=${kinds[i]}
done
[[ -n $kind ]] || refuse

mkdir -p "${lockDir%/*}"
if ! mkdir "$lockDir" 2>/dev/null; then
  record "$verb $vm 75 busy"
  echo "ndh-vz-recover: another recovery is running" >&2
  exit 75
fi
trap 'rmdir "$lockDir"' EXIT

sw=/run/current-system/sw/bin
status=0
case $verb:$kind in
  restart:*)
    launcher=$HOME/.tart/vms/$vm/$vm.sh
    if [[ ! -x $launcher ]]; then
      record "restart $vm 66 no-launcher"
      echo "ndh-vz-recover: no launcher at $launcher" >&2
      exit 66
    fi
    # A stopped VM makes stop fail; the launcher then starts it all the same, so its status is only logged.
    stopStatus=0
    "$tart" stop --timeout 60 "$vm" || stopStatus=$?
    record "restart $vm stop=$stopStatus"
    "$open" -a Terminal "$launcher" || status=$?
    ;;
  rollback:nixos) "$tart" exec "$vm" "$sw/nixos-rebuild" switch --rollback || status=$? ;;
  rollback:darwin) "$tart" exec "$vm" /usr/bin/sudo -n "$sw/darwin-rebuild" switch --rollback || status=$? ;;
  restart-access:nixos) "$tart" exec "$vm" "$sw/systemctl" restart sshd.service tailscaled.service || status=$? ;;
  restart-access:darwin)
    "$tart" exec "$vm" /usr/bin/sudo -n /bin/launchctl kickstart -k system/com.tailscale.tailscaled || status=$?
    ;;
esac
record "$verb $vm $status"
exit "$status"
