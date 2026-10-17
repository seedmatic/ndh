# Who may log in to the operator seats, and how: on every seat sshd admits the policy's AllowUsers and nobody
# else, the operator and the restricted accounts among them and root not, with neither password nor
# keyboard-interactive authentication, root refused, and PAM off; the seats admit the same accounts.
# nixpkgs' sshd -T resolves the effective settings, but it is built without PAM on darwin and drops UsePAM:
# the first UsePAM in sshd's reading order (Include globs expanded, sorted) is read here instead, as sshd
# keeps the first value it reads. Two mutants must be refused: AllowUsers gone, and macOS's own drop-in
# back with its `UsePAM yes`.
{
  pkgs,
  lib,
  # { <seat> = { files = { "ssh/sshd_config" = text; "ssh/sshd_config.d/<n>.conf" = text; }; allowUsers; operator; restrictedUsers = [ names ]; }; }
  seats,
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
  words = l: lib.escapeShellArg (lib.concatStringsSep " " (lib.sort lib.lessThan l));
  perSeat = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (seat: s: ''
      ${copyTree "$PWD/${seat}" s.files}
      verify ${lib.escapeShellArg seat} "$PWD/${seat}" ${lib.escapeShellArg s.operator} ${words s.allowUsers} ${words s.restrictedUsers} || exit 1
      admitted+=("$(admits "$PWD/${seat}" ${lib.escapeShellArg s.operator})")
      mutate ${lib.escapeShellArg seat} ${lib.escapeShellArg s.operator} ${words s.allowUsers} ${words s.restrictedUsers}
    '') seats
  );
in
pkgs.runCommand "darwin-sshd-access" { nativeBuildInputs = [ pkgs.openssh ]; } ''
  ssh-keygen -q -t ed25519 -N "" -f "$PWD/hk"
  shopt -s nullglob
  export LC_ALL=C
  effective() { # <root> <user>
    sshd -T -f "$1/etc/ssh/sshd_config" -h "$PWD/hk" -C "user=$2,host=x,addr=127.0.0.1" 2>"$PWD/err"
  }
  # OpenSSH 10 prints the keywords in their camel case, older ones in lower case; AllowUsers one per line.
  values() { awk -v o="$1" 'tolower($1) == o { $1 = ""; sub(/^ /, ""); print }'; }
  admits() { # <root> <user>: the AllowUsers list, sorted, on one line
    effective "$1" "$2" | values allowusers | sort | tr '\n' ' ' | sed 's/ $//'
  }
  # sshd's reading order: each line in turn, an Include replaced by its files in sorted glob order.
  flatten() { # <file>
    local line glob f
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ "$line" =~ ^[[:space:]]*[Ii]nclude[[:space:]]+(.*)$ ]]; then
        for glob in ''${BASH_REMATCH[1]}; do
          # Unquoted on purpose: the glob expands, sorted in the C locale as sshd's glob(3) does.
          for f in $glob; do flatten "$f"; done
        done
      else
        printf '%s\n' "$line"
      fi
    done <"$1"
  }
  first_usepam() { flatten "$1/etc/ssh/sshd_config" | awk 'tolower($1) == "usepam" { print tolower($2); exit }'; }
  verify() { # <seat> <root> <operator> <allowUsers> <restricted>
    local cfg got want
    cfg="$(effective "$2" "$3")" || { echo "FAIL $1: sshd -T refused the config"; cat "$PWD/err"; return 1; }
    for want in passwordauthentication=no kbdinteractiveauthentication=no permitrootlogin=no; do
      got="$(printf '%s\n' "$cfg" | values "''${want%%=*}" | head -1)"
      [ "$got" = "''${want#*=}" ] || { echo "FAIL $1: ''${want%%=*} = ''${got:-<unset>}, expected ''${want#*=}"; return 1; }
    done
    got="$(admits "$2" "$3")"
    [ "$got" = "$4" ] || { echo "FAIL $1: AllowUsers = ''${got:-<none>}, the policy's is $4"; return 1; }
    for want in "$3" $5; do
      [[ " $got " == *" $want "* ]] || { echo "FAIL $1: $want is not admitted"; return 1; }
    done
    [[ " $got " != *" root "* ]] || { echo "FAIL $1: root is admitted"; return 1; }
    got="$(first_usepam "$2")"
    [ "$got" = no ] || { echo "FAIL $1: the first UsePAM sshd reads is ''${got:-<none>}"; return 1; }
    echo "ok   $1: admits $4 only, no password nor keyboard-interactive, root refused, UsePAM no first"
  }
  mutate() { # <seat> <operator> <allowUsers> <restricted>: each mutant must be refused
    local name
    rm -rf "$PWD/m"; cp -R "$PWD/$1" "$PWD/m"
    find "$PWD/m" -type f -exec sed -i -e "s#$PWD/$1/#$PWD/m/#g" -e '/^AllowUsers /d' {} +
    if (verify "$1" "$PWD/m" "$2" "$3" "$4") >/dev/null 2>&1; then echo "FAIL $1: mutant 'AllowUsers gone' passed"; exit 1; fi
    echo "ok   $1: mutant 'AllowUsers gone' refused"
    rm -rf "$PWD/m"; cp -R "$PWD/$1" "$PWD/m"
    find "$PWD/m" -type f -exec sed -i -e "s#$PWD/$1/#$PWD/m/#g" {} +
    printf '# Options set by macOS that differ from the OpenSSH defaults.\nUsePAM yes\nAcceptEnv LANG LC_*\n' \
      >"$PWD/m/etc/ssh/sshd_config.d/100-macos.conf"
    if (verify "$1" "$PWD/m" "$2" "$3" "$4") >/dev/null 2>&1; then echo "FAIL $1: mutant 'macOS UsePAM yes back' passed"; exit 1; fi
    echo "ok   $1: mutant 'macOS UsePAM yes back' refused"
  }

  admitted=()
  ${perSeat}
  [ "$(printf '%s\n' "''${admitted[@]}" | sort -u | wc -l)" -eq 1 ] ||
    { echo "FAIL the seats admit different accounts:"; printf '  %s\n' "''${admitted[@]}"; exit 1; }
  echo "ok   every seat admits the same accounts: ''${admitted[0]}"
  touch $out
''
