{ lib, ... }:
# The postActivation slots of the steps that depend on each other, named once. sops-nix installs the
# secrets at lib.mkAfter (1500) in this pin, and every step that reads one must come after it: three
# readers sat at 1200-1450, each believing the install ran at 1000, and read the previous generation.
# The by-revision check modules/darwin/activation-order.d/tests/read-after-install.nix holds the rule.
{
  options.ndh.darwin.postActivationOrder = lib.mkOption {
    type = lib.types.attrsOf lib.types.int;
    readOnly = true;
    default = {
      secretsInstalled = 1500;
      cacheTrustCompose = 1600;
      nixSigningKey = 1605;
      hostKeyGenerate = 1606;
      sshKeysEnrichment = 1610;
      userSecretMirror = 1620;
      incusClusterCert = 1650;
      atticLeaf = 1660;
      restartSecretReaders = 1700;
      homeManager = 2000;
    };
    description = "mkOrder slots of the postActivation steps that depend on each other.";
  };
}
