{
  pkgs,
  stdenv,
}:
stdenv.mkDerivation {
  pname = "browseros-neo";
  version = "neo";

  src = pkgs.fetchurl {
    url = "https://cdn.browseros.com/download/BrowserOS_neo.dmg";
    sha256 = "0csiwhwwa5854hj5vhaq0h1zyg2z3q0dalxbmm09820p6662si73";
  };

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

    echo "What's in the mount dir?"
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
    mkdir -p "$out/Applications"
    cp -a "./BrowserOS neo.app" "$out/Applications/BrowserOS neo.app"
  '';

  meta = {
    description = "BrowserOS neo: a secondary browser for AI agents (Chromium fork, MCP, local).";
    homepage = "https://www.browseros.com/";
  };
}
