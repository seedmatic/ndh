{
  config,
  pkgs,
  lib,
  ndhSystemd,
  ...
}:
# Order the shared nix-store identity deploy script (defined in
# modules/.common.d/nix-store-identity.nix) after the extract pipeline so the
# source files at ${sshPaths.secretsKeysDir}/nix-store{,-cert.pub} exist when
# it runs. Mirrors the Darwin activation wiring at
# modules/darwin/linux-builder.nix for the same identity.
let
  ndhContext = config.ndh.context or { };
  generationMode = ndhContext.generationMode or "full";
  runtimeMode = generationMode != "bringup";

  sshKeysEnrichmentServiceName = ndhSystemd.mkServiceName "ssh-keys-enrichment";
  contributedTargetName = ndhSystemd.contributedTargetName;
in
{
  config = lib.mkIf runtimeMode {
    nixStoreIdentity.enable = true;

    systemd.services.${ndhSystemd.mkUnitName "nix-store-identity"} = {
      description = "Deploy cert-signed nix-store identity to ${config.nixStoreIdentity.keyPath} (@codebase)";
      wantedBy = [ contributedTargetName ];
      requires = [ sshKeysEnrichmentServiceName ];
      after = [ sshKeysEnrichmentServiceName ];
      path = with pkgs; [ coreutils ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        ExecStart = "${config.nixStoreIdentity.deployScript}/bin/nix-store-identity-deploy";
      };
    };
  };
}
