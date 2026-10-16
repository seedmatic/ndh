# A host's rendered /etc/ssh/ssh_known_hosts trusts the host authority for the fleet's names and nothing
# else (roles × keys S3a): `ssh-keygen -F` looks each name up the way ssh does, patterns included.
{
  pkgs,
  lib,
  name,
  # the rendered file's text
  knownHosts,
  # every fleet name, each to resolve to an @cert-authority line
  fleet,
  # names outside the fleet, each to resolve to no line
  outside,
}:
pkgs.runCommand "ssh-known-hosts-scope-${name}"
  {
    nativeBuildInputs = [ pkgs.openssh ];
    knownHosts = builtins.unsafeDiscardStringContext knownHosts;
    passAsFile = [ "knownHosts" ];
  }
  ''
    failures=0
    if grep -q '^@cert-authority \*' "$knownHostsPath"; then
      echo "FAIL the host authority is trusted for '*'"
      failures=$((failures + 1))
    fi
    for host in ${lib.escapeShellArgs fleet}; do
      if ssh-keygen -F "$host" -f "$knownHostsPath" | grep -q '^@cert-authority '; then
        echo "ok   $host: vouched for by the host authority"
      else
        echo "FAIL $host: no @cert-authority line"
        failures=$((failures + 1))
      fi
    done
    for host in ${lib.escapeShellArgs outside}; do
      if ssh-keygen -F "$host" -f "$knownHostsPath" >/dev/null; then
        echo "FAIL $host: outside the fleet, yet trusted"
        failures=$((failures + 1))
      else
        echo "ok   $host: not trusted"
      fi
    done
    [ "$failures" -eq 0 ]
    touch $out
  ''
