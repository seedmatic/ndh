# offtailnet-screens-check, BUILT, against a stubbed resolver and a stubbed nft: the set is rebuilt from
# what MagicDNS vouches for alone, and anything else leaves it empty and fails.
{
  pkgs,
  ndh,
}:
let
  inherit (pkgs) lib;
  openings = pkgs.writeText "openings.json" (
    builtins.toJSON [
      {
        name = "rdp-a";
        vip = "100.73.0.1";
        port = "5900";
      }
      {
        name = "rdp-b";
        vip = "100.77.0.2";
        port = "5900";
      }
    ]
  );
  # dig answers from DIG_ANSWERS ("fqdn=address" per line, one line per A record, so a name listed
  # twice answers two records), and says nothing for a name not listed. The queried name is the
  # argument after the record type, never the `@resolver`.
  dig = pkgs.writeShellScriptBin "dig" ''
    q=""; prev=""
    for a in "$@"; do [ "$prev" = A ] && q=$a; prev=$a; done
    grep -F "''${q}=" "''${DIG_ANSWERS:?}" 2>/dev/null | cut -d= -f2
  '';
  # nft records each call; the set's content is what the last flush leaves plus what was added after.
  nft = pkgs.writeShellScriptBin "nft" ''
    printf '%s\n' "$*" >>"''${NFT_CALLS:?}"
  '';
  check = ndh.store.installBinScript "offtailnet-screens-check" (
    pkgs.replaceVars ../offtailnet-screens-check.sh {
      nixBashTrampoline = "${ndh.context.nixBashTrampoline}";
      loggerTag = "test.offtailnet-screens-check";
      toolPath = lib.makeBinPath [
        pkgs.coreutils
        pkgs.gnugrep
        dig
        nft
        pkgs.yq-go
      ];
      inherit openings;
      setName = "offtailnet_screens";
      tailnetDomain = "example.ts.net";
    }
  );
in
pkgs.runCommand "offtailnet-screens-check-bats"
  {
    nativeBuildInputs = [ pkgs.bats ];
    CHECK = "${check}/bin/offtailnet-screens-check";
  }
  ''
    cp ${./screens-check.bats} screens-check.bats
    bats screens-check.bats
    touch $out
  ''
