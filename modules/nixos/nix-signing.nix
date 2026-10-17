{
  config,
  lib,
  ...
}:
# NixOS wiring for the builder's derived nix signing key (modules/.common.d/nix-signing.nix). nix reads the file at
# each signing and fails the build when it is missing, so the daemon requires the oneshot: Before= only orders, and
# a socket-activated daemon started early in boot pulls the unit into the same transaction this way.
lib.mkIf config.ndh.nixSigning.signs {
  systemd.services.ndh-nix-signing-key = {
    description = "Place this machine's nix signing key, derived from its own host key (@codebase)";
    requiredBy = [ "nix-daemon.service" ];
    before = [ "nix-daemon.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
      Group = "root";
      ExecStart = "${config.ndh.nixSigning.placeScript}/bin/ndh-nix-signing-key";
    };
  };
}
