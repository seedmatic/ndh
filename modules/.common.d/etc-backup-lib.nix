{ lib }:
let
  mkManagedSymlinkCase = managedPrefixes:
    lib.concatStringsSep "\n" (
      map (
        prefix: ''
                      ${prefix}*)
                        continue
                        ;;
        ''
      ) managedPrefixes
    );
in
{
  mkEtcBackupScript =
    {
      etcTargets,
      extension,
      overwrite ? true,
      managedPrefixes ? [ "/nix/store/" ],
      moveConflicts ? true,
    }:
    let
      etcTargetsLines = lib.concatStringsSep "\n" etcTargets;
      writeAction = if moveConflicts then "mv \"$target\" \"$backup\"" else "cp -a \"$target\" \"$backup\"";
    in
    ''
      set -eu

      while IFS= read -r relpath; do
        [ -n "$relpath" ] || continue

        target="/etc/$relpath"
        backup="$target.${extension}"

        if [ ! -e "$target" ] && [ ! -L "$target" ]; then
          continue
        fi

        if [ -L "$target" ]; then
          resolved="$(readlink "$target" || true)"
          case "$resolved" in
      ${mkManagedSymlinkCase managedPrefixes}
          esac
        fi

        mkdir -p "$(dirname "$backup")"

        if [ -e "$backup" ] || [ -L "$backup" ]; then
          if ${lib.boolToString overwrite}; then
            rm -rf "$backup"
          else
            continue
          fi
        fi

        ${writeAction}
      done <<'EOF'
      ${etcTargetsLines}
      EOF
    '';
}
