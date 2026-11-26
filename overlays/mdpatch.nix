inputs: final: prev:
let
  mdpatchSrc = final.fetchurl {
    url = "https://registry.npmjs.org/markdown-patch/-/markdown-patch-2.1.0.tgz";
    hash = "sha256-mRL0DbDiSnMD3sdZcyD4YHJKMhO3dNidvLczWBhT/TE=";
  };
  depVersions = {
    commander = "12.1.0";
    marked = "17.0.1";
    yaml = "2.5.1";
    zod = "3.25.76";
  };
  depHashes = {
    commander = "sha256-Vq/8bdr+SG+UtCiuKCPQWc9g1Nri8z6q8bHsQwb3MXM=";
    marked = "sha256-0JvEBndItxrxMaJhVQGTz++6AU9nlx84kPImkpP1pgs=";
    yaml = "sha256-YFhBQWFwMc1XXcxlIbHGmW6CvwNm3d0AwSGrtA/QSPc=";
    zod = "sha256-nh8aBfDdDB2rZO6Rzrm/Vc1E01Noxw7dqAov3HCog3c=";
  };
  mkDep =
    name:
    final.fetchurl {
      url = "https://registry.npmjs.org/${name}/-/${name}-${depVersions.${name}}.tgz";
      hash = depHashes.${name};
    };
  depNames = [
    "commander"
    "marked"
    "yaml"
    "zod"
  ];
  mdpatch = final.stdenv.mkDerivation {
    pname = "markdown-patch";
    version = "2.1.0";
    src = mdpatchSrc;
    nativeBuildInputs = [ final.makeWrapper ];
    dontBuild = true;
    installPhase = ''
      mkdir -p $out/lib/mdpatch
      tar -xzf ${mdpatchSrc} -C $out/lib/mdpatch --strip-components=1
      mkdir -p $out/lib/mdpatch/node_modules
      ${final.lib.concatStringsSep "\n" (
        map (d: ''
          mkdir -p $out/lib/mdpatch/node_modules/${d}
          tar -xzf ${mkDep d} -C $out/lib/mdpatch/node_modules/${d} --strip-components=1
        '') depNames
      )}
      mkdir -p $out/bin
      makeWrapper ${final.nodejs}/bin/node $out/bin/mdpatch \
        --add-flags "$out/lib/mdpatch/dist/cli.js" \
        --set NODE_PATH "$out/lib/mdpatch/node_modules"
    '';
    meta = {
      description = "Structure-aware Markdown patching CLI (mdpatch)";
      license = final.lib.licenses.mit;
      mainProgram = "mdpatch";
    };
  };
in
{
  mdpatch = mdpatch;
}
