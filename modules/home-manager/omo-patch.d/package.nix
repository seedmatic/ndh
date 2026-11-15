{ pkgs }:
let
  base = pkgs.writeShellApplication {
    name = "omo-patch";
    runtimeInputs = with pkgs; [
      coreutils
      diffutils
      findutils
      gawk
      gnused
      mdpatch
      yq-go
    ];
    text = builtins.readFile ./omo-patch.sh;
  };
in
pkgs.runCommand "omo-patch" { } ''
  mkdir -p $out/bin $out/share/omo-patch
  cp ${base}/bin/omo-patch $out/bin/omo-patch
  chmod +x $out/bin/omo-patch
  if [ -d ${./../omo.d} ]; then
    mkdir -p $out/share/omo-patch/omo.d
    cp -r ${./../omo.d}/. $out/share/omo-patch/omo.d/
  fi
  mkdir -p $out/share/omo-patch/agent.d
''
