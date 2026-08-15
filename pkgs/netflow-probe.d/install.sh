# Renders and loads the softflowd NetFlow LaunchDaemon on the bare-metal vz
# host (nikopol-vz), which lives OUTSIDE the ndh nix-darwin fleet: it has a nix
# store (receives `nix copy`) but no darwin-rebuild activation, so the plist is
# materialised here at deploy time rather than baked by a system module.
#
# Build-time tokens (@softflowd@, @label@, @plist@, @log@) are substituted by
# pkgs.replaceVars; interface/collector/version are runtime arguments.

# launchctl and the BSD file tools live in the macOS system paths, outside the
# writeShellApplication curated PATH.
PATH="/bin:/usr/bin:/sbin:/usr/sbin:$PATH"

collector="${1:-${NETFLOW_COLLECTOR:-}}"
interface="${NETFLOW_INTERFACE:-en0}"
version="${NETFLOW_VERSION:-9}"

if [[ -z "$collector" ]]; then
  echo "usage: netflow-probe-install <collector-host:port>" >&2
  echo "  (or NETFLOW_COLLECTOR=...; NETFLOW_INTERFACE defaults to en0, NETFLOW_VERSION to 9)" >&2
  exit 2
fi
if [[ "$(id -u)" -ne 0 ]]; then
  echo "netflow-probe-install must run as root (BPF capture on $interface + /Library/LaunchDaemons)" >&2
  exit 1
fi

umask 022
cat > "@plist@" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>@label@</string>
  <key>ProgramArguments</key>
  <array>
    <string>@softflowd@/bin/softflowd</string>
    <string>-d</string>
    <string>-i</string><string>${interface}</string>
    <string>-n</string><string>${collector}</string>
    <string>-v</string><string>${version}</string>
    <string>-T</string><string>full</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>@log@</string>
  <key>StandardErrorPath</key><string>@log@</string>
</dict>
</plist>
PLIST

chown root:wheel "@plist@"
chmod 0644 "@plist@"

# `-d` keeps softflowd in the foreground so launchctl KeepAlive can supervise it
# (a forking daemon would look dead to launchd after the first fork).
launchctl bootout system "@plist@" 2>/dev/null || true
launchctl bootstrap system "@plist@"
launchctl enable "system/@label@"

echo "[netflow-probe] loaded: softflowd -i ${interface} -n ${collector} -v ${version}  (log: @log@)" >&2
