# ndh's .sops.yaml names exactly, in every creation rule: the age of each host slot keys.json records with
# `recipient: true`, plus the standalone operator, nothing else (the interim recipients left at step ⑥, 2026-10-29).
# Two mutants must be refused: a recipient added, a recorded one removed.
{
  pkgs,
  sopsYaml,
  keysJson,
}:
let
  lib = pkgs.lib;
  # Never in keys.yaml: the key that opens a file must not live inside that file.
  standalone = {
    ${import ../operator-recipient.nix} = "the operator";
  };
  standaloneLines = pkgs.writeText "standalone" (
    lib.concatMapStrings (r: r + "\n") (lib.attrNames standalone)
  );
in
pkgs.runCommand "sops-recipients"
  {
    nativeBuildInputs = with pkgs; [
      coreutils
      diffutils
      gnugrep
      gnused
      yq-go
    ];
  }
  ''
    rule() { yq -r ".creation_rules[$2].age[]" "$1" | sort -u; } # <.sops.yaml> <index>
    # The hosts' recorded age that keys.json marks recipient.
    recorded=$(yq -p json -r '.keys | to_entries[] | .value.slots // {} | .[] | select(.recipient == true) | .age' ${keysJson} | sort -u)
    [ -n "$recorded" ] || { echo "FAIL keys.json marks no host slot recipient: K1's fields are missing"; exit 1; }
    expected() { # <keys.json>: the recorded recipients and the standalone ones
      { yq -p json -r '.keys | to_entries[] | .value.slots // {} | .[] | select(.recipient == true) | .age' "$1"
        cat ${standaloneLines}
      } | sort -u
    }
    verify() { # <.sops.yaml> <keys.json>
      local n i want got
      want=$(expected "$2")
      n=$(yq -r '.creation_rules | length' "$1")
      [ "$n" -gt 0 ] || { echo "FAIL $1 has no creation rule"; return 1; }
      for i in $(seq 0 $((n - 1))); do
        got=$(rule "$1" "$i")
        if [ "$got" != "$want" ]; then
          echo "FAIL $1 rule $i is not keys.yaml's recipients:"
          diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | grep '^[<>]' | sed 's/^</  missing/; s/^>/  extra  /'
          return 1
        fi
      done
    }
    verify ${sopsYaml} ${keysJson}
    echo "ok   every rule = keys.yaml's recipients + the operator ($(wc -l <<<"$recorded") recorded)"
    mutant() { # <name> <.sops.yaml> <keys.json> <the refusal it must meet>
      if why=$(verify "$2" "$3"); then echo "FAIL mutant '$1' passed"; exit 1; fi
      case "$why" in
        *"$4"*) echo "ok   mutant '$1' refused: $4" ;;
        *) echo "FAIL mutant '$1' refused for another reason: $why"; exit 1 ;;
      esac
    }
    yq '.creation_rules[0].age += ["age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs5zkf3q"]' ${sopsYaml} >added.yaml
    mutant "a recipient added" added.yaml ${keysJson} "extra"
    first=$(head -1 <<<"$recorded")
    R=$first yq '.creation_rules[].age |= map(select(. != strenv(R)))' ${sopsYaml} >removed.yaml
    mutant "a recorded one removed" removed.yaml ${keysJson} "missing"
    touch $out
  ''
