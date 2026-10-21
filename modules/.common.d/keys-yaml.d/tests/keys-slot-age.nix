# A slot's recorded `age` is ssh-to-age of its own public, and `recipient` says truly whether that age is a recipient
# of ndh's .sops.yaml: of EVERY creation rule (true) or of none (false). Recorded, not derived at evaluation, which
# would be import-from-derivation; held here by a build. Four mutants must be refused, each for its own reason: a
# wrong age, a true recipient missing from a rule, a false one present, and one present in some rules only.
{
  pkgs,
  keysJson,
  sopsYaml,
}:
pkgs.runCommand "keys-slot-age"
  {
    nativeBuildInputs = with pkgs; [
      coreutils
      gnugrep
      jq
      ssh-to-age
      yq-go
    ];
  }
  ''
    yq -o=json '[.creation_rules[].age]' ${sopsYaml} >rules.json
    verify() { # <keys.json>
      jq -r '.keys | to_entries[] | .key as $k | .value.type as $t | .value.slots | to_entries[]
          | select(.value | has("age")) | [$k, .key, $t, .value.public, .value.age, (.value.recipient | tostring)] | @tsv' "$1" |
        while IFS=$'\t' read -r key slot type public age recipient; do
          derived=$(printf '%s %s\n' "$type" "$public" | ssh-to-age)
          if [ "$derived" != "$age" ]; then echo "FAIL $key@$slot: age is not ssh-to-age of its public"; return 1; fi
          rules=$(jq --arg a "$age" '[.[] | index($a) != null] | map(select(.)) | length' rules.json)
          total=$(jq length rules.json)
          case "$recipient/$rules" in
            true/"$total" | false/0) ;;
            true/*) echo "FAIL $key@$slot: recipient true, but missing from $((total - rules)) of the $total rules"; return 1 ;;
            false/*) echo "FAIL $key@$slot: recipient false, but in $rules of the $total rules"; return 1 ;;
            *) echo "FAIL $key@$slot: an age without a recipient flag"; return 1 ;;
          esac
        done
    }
    mutant() { # <name> <keys.json jq | rules.json jq> <the refusal it must meet>
      cp rules.json rules.saved
      case "$2" in
        rules:*) jq "''${2#rules:}" rules.saved >rules.json; cp ${keysJson} mutant.json ;;
        *) jq "$2" ${keysJson} >mutant.json ;;
      esac
      if why=$(verify mutant.json); then echo "FAIL mutant '$1' passed"; exit 1; fi
      cp rules.saved rules.json
      case "$why" in
        *"$3"*) echo "ok   mutant '$1' refused: $3" ;;
        *) echo "FAIL mutant '$1' refused for another reason: $why"; exit 1 ;;
      esac
    }
    verify ${keysJson}
    n=$(jq '[.keys[].slots[] | select(has("age"))] | length' ${keysJson})
    [ "$n" -gt 0 ] || { echo "FAIL no slot records an age: the check would hold nothing"; exit 1; }
    echo "ok   $n slots: each age is its public's, each recipient flag matches .sops.yaml"

    first='[.keys | to_entries[] | .key as $k | .value.slots | to_entries[] | select(.value | has("age")) | [$k, .key, .value.recipient]]'
    true_slot=$(jq -c "$first | map(select(.[2] == true)) | first" ${keysJson})
    false_slot=$(jq -c "$first | map(select(.[2] == false)) | first" ${keysJson})
    [ "$true_slot" != null ] && [ "$false_slot" != null ] || { echo "FAIL the mutants need a true and a false slot"; exit 1; }
    tk=$(jq -r '.[0]' <<<"$true_slot") ts=$(jq -r '.[1]' <<<"$true_slot")
    fk=$(jq -r '.[0]' <<<"$false_slot") fs=$(jq -r '.[1]' <<<"$false_slot")
    tage=$(jq -r --arg k "$tk" --arg s "$ts" '.keys[$k].slots[$s].age' ${keysJson})
    fage=$(jq -r --arg k "$fk" --arg s "$fs" '.keys[$k].slots[$s].age' ${keysJson})
    mutant "a wrong age" ".keys[\"$tk\"].slots[\"$ts\"].age = \"$fage\"" "age is not ssh-to-age of its public"
    mutant "a true recipient missing" "rules:map(map(select(. != \"$tage\")))" "recipient true, but missing"
    mutant "a false recipient present" "rules:map(. + [\"$fage\"])" "recipient false, but in"
    mutant "a recipient in some rules only" "rules:(.[0] |= map(select(. != \"$tage\")))" "recipient true, but missing from 1"
    touch $out
  ''
