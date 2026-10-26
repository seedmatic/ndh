# A slot `pending` (no key yet) or `retired` (no longer used) is invisible to every consumer of keys.yaml but the
# three that declare, generate and record a key (roles × keys K5+). Each reader runs on one fixture holding a host key
# with a SERVING slot, a PENDING one (newer, no public, no certificate) and a RETIRED one (older, with a public and a
# certificate), and must see the serving slot alone. Then each reader's filter is removed in a copy: that mutant must
# see the pending or retired slot, or this check proves nothing.
{
  pkgs,
  lib,
  keysYamlModule,
  splitExp,
  enrich,
  krl,
  certify,
  renew,
}:
let
  fixture = {
    keys.host-x = {
      type = "ssh-ed25519";
      usage = [ "ssh-host" ];
      profiles = [ "system" ];
      authority = "fabric";
      cert_usage = [ "ssh-host" ];
      slots = {
        "26-01-01" = {
          public = "AAAAretired";
          state = "retired";
          origin = "keyring";
          certificates.fabric.ssh-host = "ssh-ed25519-cert-v01@openssh.com AAAAretiredcert host-x";
        };
        "26-05-01" = {
          public = "AAAAserving";
          state = "serving";
          origin = "keyring";
          certificates.fabric.ssh-host = "ssh-ed25519-cert-v01@openssh.com AAAAservingcert host-x";
        };
        "26-11-01" = {
          state = "pending";
          origin = "host";
        };
      };
    };
    authorities.fabric = {
      type = "ssh-ed25519";
      usage = [ "ssh-authority" ];
      slots."26-01-01".public = "AAAAca";
    };
  };
  fixtureJson = pkgs.writeText "hidden-slots.json" (builtins.toJSON fixture);
  # Commit dates as self.lastModified carries them: 26-05-10 inside the serving slot's 14-day overlap, 26-05-20 past it.
  self.lastModified = 1778371200;
  past.lastModified = 1779235200;

  # The nix projection: keys-yaml.nix evaluated on the fixture, as its consumers read it.
  evaluated =
    (lib.evalModules {
      modules = [
        keysYamlModule
        {
          _module.args = {
            inherit pkgs lib self;
            worktreePath.of = _: fixtureJson;
          };
        }
      ];
    }).config.ndh.keysYaml;
  seen = lib.attrNames evaluated.keys.host-x.slots;
  # The projection's mutant: keys-yaml.nix with its `hidden` list emptied must show every slot.
  mutantModule = pkgs.writeText "keys-yaml-mutant.nix" (
    builtins.replaceStrings [ "hidden = [\n    \"pending\"\n    \"retired\"\n  ];" ] [ "hidden = [ ];" ]
      (builtins.readFile keysYamlModule)
  );
  mutantSeen =
    lib.attrNames
      (lib.evalModules {
        modules = [
          (import mutantModule)
          {
            _module.args = {
              inherit pkgs lib self;
              worktreePath.of = _: fixtureJson;
            };
          }
        ];
      }).config.ndh.keysYaml.keys.host-x.slots;
  all = lib.attrNames evaluated.allSlots.host-x.slots;

  # A key revoked while a RETIRED slot still carries it: keys-yaml.nix must refuse it, retired slots included in what
  # it guards (`keys-reconcile retire` deletes the slot in the same change). Forced through krlFile, where the guard
  # throws (forcing `.keys` would reach no guard and prove nothing).
  revokedWhileRetired = fixture // {
    revoked."host-x@26-01-01" = {
      type = "ssh-ed25519";
      public = "AAAAretired";
      reason = "fixture";
    };
  };
  krlEvaluates =
    {
      module ? keysYamlModule,
      keys,
      at ? self,
    }:
    (builtins.tryEval (
      builtins.deepSeq
        (lib.evalModules {
          modules = [
            module
            {
              _module.args = {
                inherit pkgs lib;
                self = at;
                worktreePath.of = _: pkgs.writeText "keys.json" (builtins.toJSON keys);
              };
            }
          ];
        }).config.ndh.keysYaml.krlFile.drvPath
        true
    )).success;
  refusedWith =
    module:
    !(krlEvaluates {
      inherit module;
      keys = revokedWhileRetired;
    });
  # The guard's mutant: livePublics read from the projection that hides retired slots, as before the fix. Built beside a
  # copy of keys-yaml.d, so its relative imports (trust.nix, krl.sh) resolve as the original's do.
  guardMutantText =
    builtins.replaceStrings
      [ "        allSlotsJson\n        authoritiesJson" ]
      [ "        keysJson\n        authoritiesJson" ]
      (builtins.readFile keysYamlModule);
  guardMutantDir = pkgs.runCommand "keys-yaml-guard-mutant" { } ''
    mkdir -p $out && cp -r ${builtins.dirOf keysYamlModule}/keys-yaml.d $out/keys-yaml.d
    cp ${pkgs.writeText "keys-yaml.nix" guardMutantText} $out/keys-yaml.nix
  '';
  guardMutant = "${guardMutantDir}/keys-yaml.nix";
in
assert lib.assertMsg (
  seen == [ "26-05-01" ]
) "hidden-slots: ndh.keysYaml.keys shows ${builtins.toJSON seen}";
assert lib.assertMsg (
  all == [
    "26-01-01"
    "26-05-01"
    "26-11-01"
  ]
) "hidden-slots: ndh.keysYaml.allSlots lost a slot: ${builtins.toJSON all}";
assert lib.assertMsg (
  builtins.readFile mutantModule != builtins.readFile keysYamlModule
) "hidden-slots: the projection's mutant changed nothing";
assert lib.assertMsg (
  lib.length mutantSeen == 3
) "hidden-slots: the projection's mutant still hides slots: ${builtins.toJSON mutantSeen}";
assert lib.assertMsg (refusedWith keysYamlModule)
  "hidden-slots: a key revoked while a retired slot still carries it was accepted";
assert lib.assertMsg (
  guardMutantText != builtins.readFile keysYamlModule
) "hidden-slots: the guard's mutant changed nothing";
assert lib.assertMsg (!(refusedWith (import guardMutant)))
  "hidden-slots: the guard's mutant (livePublics without retired slots) still refused it: the case proves nothing";
# The overlap: a retired host slot is accepted 9 days after its successor, refused 19 days after; both sides, so the
# check neither refuses everything nor nothing.
assert lib.assertMsg (krlEvaluates {
  keys = fixture;
}) "hidden-slots: a retired slot inside its 14-day overlap was refused";
assert lib.assertMsg (
  !(krlEvaluates {
    keys = fixture;
    at = past;
  })
) "hidden-slots: a retired slot 19 days past its successor was accepted";
pkgs.runCommand "keys-yaml-hidden-slots"
  {
    nativeBuildInputs = with pkgs; [
      bash
      coreutils
      gnugrep
      gnused
      yq-go
    ];
  }
  ''
    yq -P '.' ${fixtureJson} >keys.yaml

    # split-exp: what the activation would install, and the presented slot (a file with no slot suffix).
    export TMPDIR=$PWD/
    # Its output is a stream of documents, one per file to write: gathered into one list.
    splitexp() { yq eval --from-file "$1" keys.yaml | yq ea -o json -I0 '[.]'; }
    files=$(splitexp ${splitExp})
    if [ "$(yq -r '[.[] | select((.rel_path | test("^host-x")) and .content == "")] | length' <<<"$files")" != 0 ]; then
      echo "FAIL split-exp installs an empty line for host-x"; exit 1
    fi
    presented=$(yq -r '[.[] | select(.rel_path == "host-x.pub")][0].content' <<<"$files")
    [ "$presented" = "ssh-ed25519 AAAAserving host-x" ] || { echo "FAIL split-exp presents: $presented"; exit 1; }
    if grep -qE 'host-x-26-(01|11)-01' <<<"$files"; then echo "FAIL split-exp installs a hidden slot"; exit 1; fi
    echo "ok   split-exp: the serving slot is presented, the pending and retired ones install nothing"

    # The mutant: split-exp without its filter must see the pending slot.
    sed 's/map(select((.value.state \/\/ "") != "pending" and (.value.state \/\/ "") != "retired")) | //' ${splitExp} >split-exp.mutant
    ! cmp -s split-exp.mutant ${splitExp} || { echo "FAIL the split-exp mutant changed nothing"; exit 1; }
    mutant=$(splitexp split-exp.mutant)
    [ "$(yq -r '[.[] | select(.rel_path == "host-x.pub")][0].content' <<<"$mutant")" != "ssh-ed25519 AAAAserving host-x" ] ||
      { echo "FAIL the split-exp mutant still presents the serving slot: the filter proves nothing"; exit 1; }
    echo "ok   mutant: split-exp without its filter presents another slot"

    # The enrichment's slot list (sourced, its functions alone).
    enrichslots() { # <script>
      inputFile=keys.yaml bash -c 'log::error() { echo "$*" >&2; }; source <(sed -n "/^usableSlots=/,/^key::assert_slots/p" "$1"); key::slots host-x' _ "$1"
    }
    [ "$(enrichslots ${enrich} | tr '\n' ' ')" = "26-05-01 " ] || { echo "FAIL enrichment slots: $(enrichslots ${enrich})"; exit 1; }
    sed 's/^usableSlots=.*/usableSlots=""/' ${enrich} >enrich.mutant
    [ "$(enrichslots enrich.mutant | wc -l)" = 3 ] || { echo "FAIL the enrichment mutant does not see the hidden slots"; exit 1; }
    echo "ok   enrichment: key::slots lists the serving slot alone; its mutant lists all three"

    # The KRL's certificate loop and the seat tools' slot lists, run as they run, on the fixture.
    # The filter as each tool writes it, its quotes escaped or not (certify and renew put it in a double-quoted string).
    filterOf() { sed 's/\\"/"/g' "$1" | grep -o 'with_entries(select((.value.state // "") != "pending" and (.value.state // "") != "retired"))' | head -1; }
    for tool in ${krl} ${certify} ${renew}; do
      f=$(filterOf "$tool")
      [ -n "$f" ] || { echo "FAIL $tool has no pending/retired filter"; exit 1; }
    done
    krlslots() { yq -r "(.keys // {}) | to_entries[] | (.value.slots // {}) | $1 | keys | .[]" keys.yaml | tr '\n' ' '; }
    [ "$(krlslots "$(filterOf ${krl})")" = "26-05-01 " ] || { echo "FAIL krl's filter keeps: $(krlslots "$(filterOf ${krl})")"; exit 1; }
    [ "$(krlslots 'with_entries(.)')" = "26-01-01 26-05-01 26-11-01 " ] || { echo "FAIL the unfiltered mutant does not see three slots"; exit 1; }
    echo "ok   krl, ssh-keys-certify, ssh-keys-renew: the one filter keeps the serving slot; without it, all three"
    touch $out
  ''
