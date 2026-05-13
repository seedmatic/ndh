{ buildGoModule, lib }:

buildGoModule rec {
  pname = "ndh-mdns-publish";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./go.mod
      ./go.sum
      ./main.go
    ];
  };

  vendorHash = "sha256-YF6kWhL7A3D4j65qm2+G1+DnHo4lGqUPNBoeie/UvNY=";

  ldflags = [
    "-s"
    "-w"
  ];

  # Pure mDNS publisher; no tests shipped in this tiny CLI.
  doCheck = false;

  meta = {
    description = "Publish an mDNS A+SRV record for an arbitrary <name>.local alias";
    longDescription = ''
      ndh-mdns-publish is a long-lived process that advertises a single
      DNS-SD instance under `_headscale-bootstrap._tcp.local.` so that a
      fleet-scoped alias (e.g. `headscale.mammoth-skate.local`) resolves
      to whichever host currently owns the headscale control-plane.

      Used by the Darwin and NixOS headscale-daemon modules; exactly one
      host should run it at a time so the alias points at a single owner.
    '';
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
    mainProgram = "ndh-mdns-publish";
  };
}
