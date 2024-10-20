inputs: final: prev: {
  zen-browser = let
    zenVersion = "1.0.1-a.12"; # Update this to the latest version

    mkZenBrowser = {
      system,
      variant,
    }: let
      extension =
        if system == "darwin"
        then "dmg"
        else if system == "linux"
        then "tar.bz2"
        else "zip";
      systemName =
        if system == "darwin"
        then "macos"
        else if system == "linux"
        then "linux"
        else "win";
      archSuffix =
        if system == "aarch64-darwin"
        then "-aarch64"
        else if system == "x86_64-darwin"
        then "-x64"
        else "";
      variantSuffix =
        if variant == "generic"
        then "-generic"
        else "-specific";
    in
      final.stdenv.mkDerivation {
        pname = "zen-browser";
        version = zenVersion;

        src = final.fetchurl {
          url = "https://github.com/zen-browser/desktop/releases/download/${zenVersion}/zen.${systemName}${archSuffix}${variantSuffix}.${extension}";
          sha256 = "sha256-REPLACE_WITH_ACTUAL_HASH="; # You'll need to replace this for each variant
        };

        nativeBuildInputs =
          [final.makeWrapper]
          ++ (
            if final.stdenv.isDarwin
            then [final.undmg]
            else []
          )
          ++ (
            if final.stdenv.isLinux
            then [final.gnutar final.bzip2]
            else []
          );

        unpackPhase =
          if final.stdenv.isDarwin
          then ''
            undmg $src
          ''
          else if final.stdenv.isLinux
          then ''
            tar xjf $src
          ''
          else ''
            unzip $src
          '';

        installPhase =
          if final.stdenv.isDarwin
          then ''
            mkdir -p $out/Applications
            cp -r *.app $out/Applications/
            mkdir -p $out/bin
            makeWrapper $out/Applications/*.app/Contents/MacOS/zen $out/bin/zen-browser
          ''
          else if final.stdenv.isLinux
          then ''
            mkdir -p $out/opt/zen-browser $out/bin
            cp -r * $out/opt/zen-browser/
            makeWrapper $out/opt/zen-browser/zen $out/bin/zen-browser
          ''
          else ''
            mkdir -p $out/opt/zen-browser $out/bin
            cp -r * $out/opt/zen-browser/
            makeWrapper $out/opt/zen-browser/zen.exe $out/bin/zen-browser
          '';

        meta = with final.lib; {
          description = "Zen Browser";
          homepage = "https://zen-browser.com";
          platforms = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" "x86_64-windows"];
          license = licenses.mpl20;
        };
      };
  in {
    specific = mkZenBrowser {
      system = final.stdenv.hostPlatform.system;
      variant = "specific";
    };
    generic = mkZenBrowser {
      system = final.stdenv.hostPlatform.system;
      variant = "generic";
    };
    default = mkZenBrowser {
      system = final.stdenv.hostPlatform.system;
      variant = "specific";
    };
  };
}
