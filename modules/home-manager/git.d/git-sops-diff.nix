# The git sops DIFF driver as a self-contained package: a textconv per format that renders a sops
# blob decrypted, so `git diff` shows what moved. A diff driver only — sops files stay encrypted on
# disk everywhere and are opened in memory by their readers, so no clean/smudge filter exists.
#
# It bakes its OWN store path as `sopsConfigHome`: the top-level `sops` include and every
# per-format fragment resolve the textconv to the script INSIDE this output, so a single
# `include.path = ${this}/sops` wires everything — immutable, location- and platform-independent.
#
# `sops` + `yq` are NOT baked in: they are runtime PATH deps the consumer supplies (the
# operator's home.packages), as the dispatcher calls them (bare `sops`/`yq`).
{
  lib,
  stdenvNoCC,
}:
let
  formats = [
    "binary"
    "yaml"
    "json"
    "xml"
    "props"
    "csv"
    "tsv"
    "base64"
    "uri"
    "toml"
    "lua"
  ];
in
stdenvNoCC.mkDerivation {
  name = "git-sops-diff";
  buildCommand = ''
    mkdir -p $out/sops.d

    # The dispatcher, its @sopsConfigHome@ pointed at this output's sops.d.
    substitute ${./sops.sh} $out/sops-dispatch --subst-var-by sopsConfigHome "$out/sops.d"
    chmod +x $out/sops-dispatch

    # Per-format git config fragments — the textconv commands point at the script here.
    for fmt in ${lib.concatStringsSep " " formats}; do
      substitute ${./sops.d}/$fmt $out/sops.d/$fmt --subst-var-by sopsConfigHome "$out/sops.d"
    done

    # One textconv symlink per format — the dispatcher reads argv[0] for the format.
    for fmt in ${lib.concatStringsSep " " formats}; do
      ln -s $out/sops-dispatch $out/sops.d/$fmt-textconv
    done

    # The top-level include file (relative `path = sops.d/<fmt>`), verbatim.
    cp ${./sops} $out/sops
  '';
}
