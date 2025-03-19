inputs: final: prev: {
  podman = let
    pkgs = inputs.nixpkgs.legacyPackages.${prev.system};
    oldVersion = builtins.parseDrvName prev.podman.name;
    newVersion = "5.4.1";
  in
    if builtins.compareVersions oldVersion.version newVersion == -1
    then
      builtins.trace "Overriding podman: oldVersion=${oldVersion.version}, newVersion=${newVersion}"
      (pkgs.buildGoModule rec {
        pname = "podman";
        version = newVersion;
        src = pkgs.fetchFromGitHub {
          owner = "containers";
          repo = "podman";
          rev = "v${version}";
          sha256 = "11qiqkndjl3m8vzal1fx4lb3h4jv7aplasqjfi5y0a9rpq2wqaj6";
        };
        vendorSha256 = pkgs.lib.fakeSha256; # Disable vendor folder validation
        installPhase = prev.podman.installPhase;
      })
    else prev.podman;
}
