# The EFFECTIVE ssh client settings of a host (an operator seat or a NixOS guest), from its rendered
# /etc/ssh/ssh_config and every drop-in it includes: `ssh -G` resolves them the way a connection would,
# first value wins. Checking the stanzas one by one missed that a leading `Host *` shadowed all of them.
{
  pkgs,
  lib,
  # environment.etc of the host under test
  etc,
  # [ { target = "root@bioskop-nixos"; option = "stricthostkeychecking"; value = "true"; } ... ]
  expect,
  name,
}:
let
  # A NixOS entry declares `text = null` when it is given by `source`: its stanzas are not read here.
  sshFiles = lib.filterAttrs (n: v: lib.hasPrefix "ssh/ssh_config" n && (v.text or null) != null) etc;
  copyLines = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      n: v:
      let
        # Without context: `ssh -G` opens none of the paths the stanzas name, so a NixOS guest's
        # (Linux) store paths need no build here.
        rendered = pkgs.writeText (builtins.baseNameOf n) (
          builtins.replaceStrings [ "/etc/ssh/" ] [ "@ROOT@/etc/ssh/" ] (
            builtins.unsafeDiscardStringContext v.text
          )
        );
      in
      ''sed "s#@ROOT@#$root#g" ${rendered} > "$root/etc/${n}"''
    ) sshFiles
  );
  checkLines = lib.concatMapStringsSep "\n" (
    e:
    "check ${lib.escapeShellArg e.target} ${lib.escapeShellArg e.option} ${lib.escapeShellArg (builtins.unsafeDiscardStringContext e.value)}"
  ) expect;
in
pkgs.runCommand "ssh-client-effective-${name}" { nativeBuildInputs = [ pkgs.openssh ]; } ''
  root=$PWD
  mkdir -p "$root/etc/ssh/ssh_config.d"
  ${copyLines}
  failures=0
  check() { # <target> <option> <expected>
    got="$(ssh -G -F "$root/etc/ssh/ssh_config" "$1" | awk -v o="$2" '$1 == o { print $2; exit }')"
    if [ "$got" = "$3" ]; then
      echo "ok   $1: $2 = $got"
    else
      echo "FAIL $1: $2 = ''${got:-<unset>}, expected $3"
      failures=$((failures + 1))
    fi
  }
  ${checkLines}
  [ "$failures" -eq 0 ]
  touch $out
''
