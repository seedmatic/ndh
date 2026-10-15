# The git sops drivers as a self-contained package: a textconv per format that renders a sops blob
# decrypted, so `git diff` shows what moved; and, for yaml and binary, the clean/smudge filters that
# encrypt at `git add` and decrypt at checkout. They act only where a .gitattributes names them
# (keyhole), never in a repository holding a flake at any depth, and Claude sessions neutralise them.
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
  # The formats with a clean/smudge filter: binary is what keyhole's .gitattributes name; yaml stays
  # available to any repository without a flake.
  filterFormats = [
    "yaml"
    "binary"
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

    # One textconv symlink per format — the dispatcher reads argv[0] for the format and operation.
    for fmt in ${lib.concatStringsSep " " formats}; do
      ln -s $out/sops-dispatch $out/sops.d/$fmt-textconv
    done
    for fmt in ${lib.concatStringsSep " " filterFormats}; do
      ln -s $out/sops-dispatch $out/sops.d/$fmt-clean
      ln -s $out/sops-dispatch $out/sops.d/$fmt-smudge
    done

    # The top-level include file (relative `path = sops.d/<fmt>`), verbatim.
    cp ${./sops} $out/sops
  '';
}
