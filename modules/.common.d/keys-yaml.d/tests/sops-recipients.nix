# ndh's .sops.yaml names exactly, in every creation rule: the age of each host slot keys.json records with
# `recipient: true`, plus an explicit allowlist, one reason each. An interim entry stays allowed only while one of the
# hosts it stands in for has no slot `state: serving` with `recipient: true`: once they all do, step ⑥ (the fabric
# frame) removes it, and the check goes red if it is still there. Three mutants must be refused: a recipient added,
# a recorded one removed, an interim one that outlived its step.
{
  pkgs,
  sopsYaml,
  keysJson,
}:
let
  lib = pkgs.lib;
  # Never in keys.yaml: the key that opens a file must not live inside that file.
  standalone = {
    "age1hlvu7l7kefeum8drzvc5jp0jhgsqw2h3t3a8rmzvx05lcrsmx48q2ehxsk" = "the operator";
  };
  # Removed by step ⑥ once every host it stands in for serves its own recipient slot. Goes with ⑥, no shim.
  interim = {
    "age1fe9gs0mljq82cwxasugyrjd4pqg9h4uym5r3rwfc2084q558hd7qt4845j" = {
      why = "the NixOS guests' shared interim identity";
      hosts = [
        "bioskop-nixos"
        "nikopol-nixos"
      ];
    };
    "age17q5kw0epcl9ft7ecegr20040vx3g86z0f7vtecn9t8kk27qjspaqp66pp4" = {
      why = "darwin.nikopol's interim identity";
      hosts = [ "nikopol" ];
    };
  };
  interimLines = pkgs.writeText "interim" (
    lib.concatStrings (lib.mapAttrsToList (r: i: "${r} ${lib.concatStringsSep "," i.hosts}\n") interim)
  );
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
    serves() { # <host>: has a slot serving with recipient
      [ "$(HOST=$1 yq -p json -r '[.keys[strenv(HOST)].slots // {} | .[] | select(.state == "serving" and .recipient == true)] | length' "$2")" -gt 0 ]
    }
    expected() { # <keys.json>: the recorded recipients, the standalone ones, and each interim one still needed
      local r hosts h needed
      { yq -p json -r '.keys | to_entries[] | .value.slots // {} | .[] | select(.recipient == true) | .age' "$1"
        cat ${standaloneLines}
        while read -r r hosts; do
          needed=false
          for h in ''${hosts//,/ }; do serves "$h" "$1" || needed=true; done
          if $needed; then echo "$r"; fi
        done <${interimLines}
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
    echo "ok   every rule = keys.yaml's recipients + the operator + the interim ones still needed ($(wc -l <<<"$recorded") recorded)"
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
    # Every host fe9g stands in for now serves its own recipient slot: ⑥ is due, so fe9g must be gone.
    yq -p json -o json '(.keys["bioskop-nixos", "nikopol-nixos"].slots[] | select(.age != null)) |= (.state = "serving" | .recipient = true)' ${keysJson} >served.json
    mutant "an interim one that outlived its step" ${sopsYaml} served.json "extra"
    touch $out
  ''
