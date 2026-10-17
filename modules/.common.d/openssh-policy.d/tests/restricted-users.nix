# The EFFECTIVE sshd settings of a host's restricted users (opensshPolicy.restrictedUsers), by the real sshd:
# `sshd -T -C user=…` resolves the Match blocks the way a login would. Each restricted user is forced to its
# command with every forwarding, the tty and ~/.ssh/rc off, and another user's settings are exactly those of the
# same host without the Match blocks: a Match runs to the end of its file, so one placed before the policy
# swallows it.
# Every mutation below must fail, or the check proves nothing.
{
  pkgs,
  lib,
  name,
  # { "ssh/sshd_config" = text; "ssh/sshd_config.d/<n>.conf" = text; ... }: the host's sshd files as rendered
  files,
  # the same files without the restricted users' text
  withoutRestricted,
  # the same files with the restricted users' text placed before the policy
  misordered,
  restrictedUsers,
  # a user that is not restricted
  otherUser,
}:
let
  copyTree =
    dir: tree:
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        n: text:
        let
          # Without context: `sshd -T` opens none of the commands the files name.
          rendered = pkgs.writeText (builtins.baseNameOf n) (
            builtins.replaceStrings [ "/etc/ssh/" ] [ "@ROOT@/etc/ssh/" ] (
              builtins.unsafeDiscardStringContext text
            )
          );
        in
        ''mkdir -p "$(dirname "${dir}/etc/${n}")"; sed "s#@ROOT@#${dir}#g" ${rendered} > "${dir}/etc/${n}"''
      ) tree
    );
  verifyLines = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      user: restricted:
      "verify_restricted \"$1\" ${lib.escapeShellArg user} ${lib.escapeShellArg (builtins.unsafeDiscardStringContext restricted.forceCommand)} || return 1"
    ) restrictedUsers
  );
in
assert lib.assertMsg (restrictedUsers != { }) "${name}: no restricted user, nothing to check";
pkgs.runCommand "sshd-restricted-users-${name}" { nativeBuildInputs = [ pkgs.openssh ]; } ''
  ssh-keygen -q -t ed25519 -N "" -f "$PWD/hk"
  effective() { # <root> <user>
    sshd -T -f "$1/etc/ssh/sshd_config" -h "$PWD/hk" -C "user=$2,host=x,addr=127.0.0.1" 2>"$PWD/err"
  }
  # OpenSSH 10 prints the keywords in their camel case, older ones in lower case.
  value() { awk -v o="$1" 'tolower($1) == o { $1 = ""; sub(/^ /, ""); print; exit }'; }
  verify_restricted() { # <root> <user> <command>
    cfg="$(effective "$1" "$2")" || { echo "FAIL $2: sshd -T refused the config"; cat "$PWD/err"; return 1; }
    for want in "forcecommand=$3" disableforwarding=yes permittty=no permituserrc=no x11forwarding=no allowagentforwarding=no; do
      got="$(printf '%s\n' "$cfg" | value "''${want%%=*}")"
      [ "$got" = "''${want#*=}" ] || { echo "FAIL $2: ''${want%%=*} = ''${got:-<unset>}, expected ''${want#*=}"; return 1; }
    done
    echo "ok   $2: forced to $3, forwarding, tty and rc off"
  }
  verify() { # <root>
    ${verifyLines}
    other="$(effective "$1" ${lib.escapeShellArg otherUser})" || { echo "FAIL ${otherUser}: sshd -T refused the config"; cat "$PWD/err"; return 1; }
    # Each tree names its own root in the paths it rewrote.
    other="$(printf '%s\n' "$other" | sed "s#$1/#@ROOT@/#g")"
    without="$(effective "$PWD/without" ${lib.escapeShellArg otherUser} | sed "s#$PWD/without/#@ROOT@/#g")"
    [ "$other" = "$without" ] || {
      echo "FAIL ${otherUser}: its settings differ from the host's without the Match blocks:"
      diff <(printf '%s\n' "$without") <(printf '%s\n' "$other") | head -10
      return 1
    }
    echo "ok   ${otherUser}: untouched by the Match blocks"
  }
  mutant() { # <name> <root>: must be refused
    if (verify "$2") >/dev/null 2>&1; then echo "FAIL mutation '$1' passed"; exit 1; fi
    echo "ok   mutation '$1' refused"
  }

  ${copyTree "$PWD/real" files}
  ${copyTree "$PWD/without" withoutRestricted}
  ${copyTree "$PWD/misordered" misordered}
  verify "$PWD/real"

  cp -R "$PWD/real" "$PWD/no-force"
  find "$PWD/no-force" -type f -exec sed -i -e "s#$PWD/real/#$PWD/no-force/#g" -e '/ForceCommand/d' {} +
  mutant "no ForceCommand" "$PWD/no-force"
  cp -R "$PWD/real" "$PWD/forwarding"
  find "$PWD/forwarding" -type f -exec sed -i -e "s#$PWD/real/#$PWD/forwarding/#g" -e 's/DisableForwarding yes/DisableForwarding no/' {} +
  mutant "DisableForwarding no" "$PWD/forwarding"
  mutant "Match blocks first" "$PWD/misordered"
  touch $out
''
