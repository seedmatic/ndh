# `ndh-trust-check`: does THIS host's live trust carry every trusted authority slot?
#
# The phase-2 gate of an authority renewal (docs/ssh-keys-renewal-spec.adoc): phase 2 drops
# the old slot, and from then on the new one signs, so every host must already trust it.
# Evaluation proves the CONFIGURATION carries every trusted slot; only the host proves its
# activated state does. Run on every host; exit 0 means every trusted slot is installed.
#
# The slots come from ndh.keysYaml.trustedAuthoritySlots — a compromised slot is not
# expected, it is checked ABSENT.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  authorities = config.ndh.keysYaml.authorities or { };
  has = usage: name: lib.elem usage (authorities.${name}.usage or [ ]);
  rowsOf =
    slotSets: usage: field: render:
    lib.concatLists (
      lib.mapAttrsToList (
        name: slots:
        lib.mapAttrsToList (slot: material: "${usage}\t${name}@${slot}\t${render name material}") (
          lib.filterAttrs (_: material: (material.${field} or "") != "") slots
        )
      ) (lib.filterAttrs (name: _: has usage name) slotSets)
    );
  pem = name: material: pkgs.writeText "${name}-trust-check-ca.crt" material.ca_crt;
  blob = _: material: material.public;
  table =
    expectation: slotSets:
    lib.concatStringsSep "\n" (
      map (row: "${expectation}\t${row}") (
        rowsOf slotSets "tls-authority" "ca_crt" pem ++ rowsOf slotSets "ssh-authority" "public" blob
      )
    );
  expectations = pkgs.writeText "ndh-trust-check.tsv" (
    lib.concatStringsSep "\n" (
      lib.filter (s: s != "") [
        (table "present" config.ndh.keysYaml.trustedAuthoritySlots)
        (table "absent" config.ndh.keysYaml.compromisedAuthoritySlots)
      ]
    )
    + "\n"
  );
  trustedCa =
    let
      path = config.opensshPolicy.trustedCAPath or null;
    in
    if path == null then "" else path;
in
{
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "ndh-trust-check";
      runtimeInputs = with pkgs; [
        coreutils
        gnugrep
        gnused
        openssl
      ];
      text = ''
        bundle=/etc/ssl/certs/ca-certificates.crt
        knownHosts=/etc/ssh/ssh_known_hosts
        trustedCa=${lib.escapeShellArg trustedCa}
        isDarwin=${if pkgs.stdenv.isDarwin then "1" else "0"}
        keychain=""
        if [[ $isDarwin == 1 ]]; then
          keychain="$(/usr/bin/security find-certificate -a -Z /Library/Keychains/System.keychain 2>/dev/null || true)"
        fi
        flatBundle="$(tr -d '\n' <"$bundle" 2>/dev/null || true)"

        failures=0
        unreadable=0
        # A store this user cannot read is NOT an absent root: say so, never answer "missing".
        readable() { # <id> <store>
          if [[ -r $2 ]]; then return 0; fi
          printf '%-4s %-7s %-40s %s\n' "SKIP" "unread" "$1" "$2 (not readable — run with sudo)"
          unreadable=$((unreadable + 1))
          return 1
        }
        report() { # <expected present|absent> <found 0|1> <id> <store>
          local verdict
          if [[ $1 == present && $2 == 1 ]] || [[ $1 == absent && $2 == 0 ]]; then
            verdict=ok
          else
            verdict=FAIL
            failures=$((failures + 1))
          fi
          printf '%-4s %-7s %-40s %s\n' "$verdict" "$1" "$3" "$4"
        }
        found() { if "$@"; then echo 1; else echo 0; fi; }

        while IFS=$'\t' read -r expected usage id value; do
          [[ -n $id ]] || continue
          case "$usage" in
            tls-authority)
              body="$(grep -v -- '-----' "$value" | tr -d '\n')"
              if readable "$id" "$bundle"; then
                report "$expected" "$(found grep -qF -- "$body" <<<"$flatBundle")" "$id" "$bundle"
              fi
              if [[ $isDarwin == 1 ]]; then
                fp="$(openssl x509 -noout -fingerprint -sha1 -in "$value" | sed -e 's/.*=//' -e 's/://g')"
                report "$expected" "$(found grep -qi -- "SHA-1 hash: $fp$" <<<"$keychain")" "$id" "System keychain"
              fi
              ;;
            ssh-authority)
              if readable "$id" "$knownHosts"; then
                report "$expected" "$(found grep -qF -- "$value" "$knownHosts")" "$id" "$knownHosts"
              fi
              if [[ -n $trustedCa ]] && readable "$id" "$trustedCa"; then
                report "$expected" "$(found grep -qF -- "$value" "$trustedCa")" "$id" "$trustedCa"
              fi
              ;;
          esac
        done <${expectations}

        if ((unreadable > 0)) && ((failures == 0)); then
          echo "ndh-trust-check: $unreadable store(s) not readable by this user — run with sudo for a verdict" >&2
          exit 2
        fi
        if ((failures > 0)); then
          echo "ndh-trust-check: $failures check(s) failed — this host does not trust what keys.yaml expects" >&2
          exit 1
        fi
        echo "ndh-trust-check: every trusted authority slot is installed, every compromised one is absent"
      '';
    })
  ];
}
