# Unloads and removes the softflowd LaunchDaemon on the bare-metal vz host.
# @label@ / @plist@ are substituted at build time by pkgs.replaceVars.

PATH="/bin:/usr/bin:/sbin:/usr/sbin:$PATH"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "netflow-probe-uninstall must run as root" >&2
  exit 1
fi

launchctl bootout system "@plist@" 2>/dev/null || true
rm -f "@plist@"

echo "[netflow-probe] removed (@label@)" >&2
