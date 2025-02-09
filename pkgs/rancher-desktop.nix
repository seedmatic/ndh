{
  lib,
  stdenv,
  p7zip,
  pkgs,
}:

let
  sources = pkgs.callPackage ../.nvfetcher/generated.nix { };
  inherit (sources.rancher-desktop) pname version src;
in
stdenv.mkDerivation {
  inherit pname version src;

  nativeBuildInputs = [ p7zip ];

  sourceRoot = ".";

  unpackPhase = ''
    7z x $src
  '';

  installPhase = ''
      runHook preInstall
      
      echo "Contents of current directory:"
      ls -la
      echo "Attempting to copy Rancher Desktop.app"
      mkdir -p $out/Applications
      cp -r "Rancher Desktop.app" $out/Applications/ || echo "Failed to copy Rancher Desktop.app"

      runHook postInstall
  '';

  meta = with lib; {
    description = "Container Management and Kubernetes on the Desktop";
    homepage = "https://rancherdesktop.io/";
    license = licenses.asl20;
    platforms = [
      "aarch64-darwin"
      "x86_64-darwin"
    ];
  };
}
