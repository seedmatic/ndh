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
      DNS-SD instance under `_headscale-bootstrap._tcp.local.` (legacy
      mDNS support, no longer used as headscale endpoint now uses
      mammoth-skate.duckdns.org for universal on-LAN/off-LAN access).

      Kept for potential future service discovery use cases.
    '';
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
    mainProgram = "ndh-mdns-publish";
  };
}
