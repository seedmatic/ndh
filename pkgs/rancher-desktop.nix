{
  pkgs,
  stdenv,
}:
let
  sources = pkgs.callPackage ../.nvfetcher/generated.nix { };
  inherit (sources.rancher-desktop) pname version src;
in
stdenv.mkDerivation {
  inherit pname version src;

  unpackCmd = ''
    echo "File to unpack: $curSrc"
    if ! [[ "$curSrc" =~ \.dmg$ ]]; then return 1; fi
    mnt=$(mktemp -d -t ci-XXXXXXXXXX)

    function finish {
      echo "Detaching $mnt"
      /usr/bin/hdiutil detach $mnt -force
      rm -rf $mnt
    }
    trap finish EXIT

    echo "Attaching $mnt"
    /usr/bin/hdiutil attach -nobrowse -readonly $src -mountpoint $mnt

    echo "What's in the mount dir"?
    ls -la $mnt/

    echo "Copying contents"
    shopt -s extglob
    DEST="$PWD"
    (cd "$mnt"; cp -a !(Applications) "$DEST/")
  '';
  sourceRoot = ".";
  dontMakeSourcesWritable = true;
  phases = [
    "unpackPhase"
    "installPhase"
  ];
  installPhase = ''
    mkdir -p "$out/Applications/Rancher Desktop.app"
    cp -a "./Rancher Desktop.app/." "$out/Applications/Rancher Desktop.app/"
  '';

  meta = {
    description = "Container Management and Kubernetes on the Desktop";
    homepage = "https://rancherdesktop.io/";
  };
}
