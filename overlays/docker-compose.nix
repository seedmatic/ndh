{ fetchFromGitHub, buildGoModule, ... }: final: prev: {
  docker-compose = let
    oldVersion = builtins.parseDrvName prev.docker-compose.name;
    newVersion = "2.31.0";  # Remove the "v" prefix
  in if builtins.compareVersions oldVersion.version newVersion == -1 then
    builtins.trace "Overriding docker-compose: oldVersion=${oldVersion.version}, newVersion=${newVersion}"
      (buildGoModule rec {
        pname = "docker-compose";
        version = newVersion;
        src = fetchFromGitHub {
          owner = "docker";
          repo = "compose";
          rev = "v${newVersion}";  # Add the "v" prefix back for the revision
          fetchSubmodules = false;
          sha256 = "sha256-l+xSd7eIpEy6A1mtx3WrcPQl7071IdJkbHKXbe4uFdA=";
        };
        vendorHash = "sha256-nBexI2hr+lKPe4HCYiNVtmc0Rl5Hhj/+TwSftYWVdQw=";
        doCheck = false;

        installPhase = ''
          runHook preInstall

          # We are in the go/src/github.com/docker/compose directory
          mkdir -p $out/bin
          cp ../go/bin/cmd $out/bin/docker-compose || 
            ( echo "Failed to copy docker-compose binary from $PWD"; exit 1 )

          runHook postInstall
        '';
      })
    else
      prev.docker-compose;
}
