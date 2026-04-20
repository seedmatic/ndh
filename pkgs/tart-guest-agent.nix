{ lib, stdenvNoCC, fetchurl }:

let
  version = "0.9.0";
  system = stdenvNoCC.hostPlatform.system;
  assetBySystem = {
    aarch64-darwin = {
      name = "tart-guest-agent-darwin-all.tar.gz";
      hash = "sha256-CZYKlNF6qNBm1t0xKFhrR8wqZCkZhRQZSZaHFMGOVZo=";
    };
    x86_64-darwin = {
      name = "tart-guest-agent-darwin-all.tar.gz";
      hash = "sha256-CZYKlNF6qNBm1t0xKFhrR8wqZCkZhRQZSZaHFMGOVZo=";
    };
    aarch64-linux = {
      name = "tart-guest-agent-linux-arm64.tar.gz";
      hash = "sha256-BQ4SVFrTZ4YDseVPR2C3G+aVhCpEFqoTLvJlfl5SN04=";
    };
    x86_64-linux = {
      name = "tart-guest-agent-linux-amd64.tar.gz";
      hash = "sha256-6C4C+d5j0S5GAIYiclq2L83rHuQH+jSkEEksq/i2Pbc=";
    };
  };
  asset =
    if builtins.hasAttr system assetBySystem then
      builtins.getAttr system assetBySystem
    else
      throw "tart-guest-agent is not available for platform ${system}";
in
stdenvNoCC.mkDerivation {
  pname = "tart-guest-agent";
  inherit version;

  src = fetchurl {
    url = "https://github.com/cirruslabs/tart-guest-agent/releases/download/v${version}/${asset.name}";
    hash = asset.hash;
  };

  sourceRoot = ".";

  installPhase = ''
    runHook preInstall

    install -d "$out/bin"

    binary_path="$(find . -type f -name tart-guest-agent | head -n 1)"
    if [[ -z "$binary_path" ]]; then
      echo "tart-guest-agent binary not found in archive" >&2
      exit 1
    fi

    install -m 0755 "$binary_path" "$out/bin/tart-guest-agent"

    runHook postInstall
  '';

  meta = {
    description = "Guest agent for Tart VMs";
    homepage = "https://github.com/cirruslabs/tart-guest-agent";
    license = lib.licenses.asl20;
    maintainers = [ ];
    platforms = builtins.attrNames assetBySystem;
    mainProgram = "tart-guest-agent";
  };
}
