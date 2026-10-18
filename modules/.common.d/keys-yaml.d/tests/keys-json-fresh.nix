# keys.json is keys.yaml's public view and nothing else: what keys-json.sh writes from keys.yaml now, byte for
# byte, with no ciphertext and no sops metadata. Three mutants must be refused: a view that is stale, one that
# holds a ciphertext, one that holds the sops metadata.
{
  pkgs,
  keysYaml,
  keysJson,
}:
pkgs.runCommand "keys-json-fresh"
  {
    nativeBuildInputs = with pkgs; [
      bash
      coreutils
      diffutils
      gnugrep
      yq-go
    ];
  }
  ''
    mkdir fresh
    cp ${keysYaml} fresh/keys.yaml
    bash -euo pipefail ${../keys-json.sh} ${../public.yq} fresh/keys.yaml
    verify() { # <view>
      if grep -qF 'ENC[' "$1"; then echo "FAIL $1 holds a sops ciphertext"; return 1; fi
      if [ "$(yq -r 'has("sops")' "$1")" != false ]; then echo "FAIL $1 holds the sops metadata"; return 1; fi
      if ! cmp -s "$1" fresh/keys.json; then
        echo "FAIL $1 is not keys.yaml's view: rewrite it from the revision, nix run …#keys-json -- modules/home-manager/ssh.d/keys.yaml"
        diff fresh/keys.json "$1" | head -20
        return 1
      fi
    }
    mutant() { # <name> <yq expression> <the refusal it must meet>
      yq -o=json "$2" ${keysJson} >mutant.json
      if why=$(verify mutant.json); then echo "FAIL mutant '$1' passed"; exit 1; fi
      case "$why" in
        *"$3"*) echo "ok   mutant '$1' refused: $3" ;;
        *) echo "FAIL mutant '$1' refused for another reason: $why"; exit 1 ;;
      esac
    }
    verify ${keysJson}
    echo "ok   keys.json is keys.yaml's view, with no ciphertext and no sops metadata"
    mutant "stale" '.revoked.mutant = {"public": "stale"}' "is not keys.yaml's view"
    mutant "a ciphertext" '.keys[(.keys | keys | .[0])].private = "ENC[AES256_GCM,data:x,type:str]"' "holds a sops ciphertext"
    mutant "the sops metadata" '.sops = {"mac": "x"}' "holds the sops metadata"
    touch $out
  ''
