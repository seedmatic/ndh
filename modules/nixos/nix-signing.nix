{
  config,
  lib,
  ...
}:
# NixOS wiring for the builder's derived nix signing key (modules/.common.d/nix-signing.nix). Wanted by nix-daemon,
# so a socket-activated daemon started early in boot pulls the unit into the same transaction, and ordered before it.
# Wanted, never required: a placement that fails (a mismatch, no host key) must not keep the daemon down, or the
# machine could not build its own fix. Builds that sign then fail loudly on the missing file, and root builds the fix
# with `--option secret-key-files ''`.
lib.mkIf config.ndh.nixSigning.signs {
  systemd.services.ndh-nix-signing-key = {
    description = "Place this machine's nix signing key, derived from its own host key (@codebase)";
    wantedBy = [ "nix-daemon.service" ];
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
