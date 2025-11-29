{ ... }: final: prev: let
  # Force lima to a CVE-fixed upstream release until nixpkgs catches up.
  version = "1.2.2";
  src = prev.fetchFromGitHub {
    owner = "lima-vm";
    repo = "lima";
    rev = "v${version}";
    hash = "sha256-bIYF/bsOMuWTkjD6fe6by220/WQGL+VWEBXmUzyXU98=";
  };
  vendorHash = "sha256-8S5tAL7GY7dxNdyC+WOrOZ+GfTKTSX84sG8WcSec2Os=";
in {
  lima = prev.lima.overrideAttrs (old: {
    inherit version src vendorHash;
    buildPhase = ''
      runHook preBuild
      make "VERSION=v${version}" "CC=cc" binaries
      runHook postBuild
    '';
    installCheckPhase = ''
      if [[ "$(HOME="$(mktemp -d)" "$out/bin/limactl" --version | cut -d ' ' -f 3)" == "${version}" ]]; then
        echo 'lima smoke check passed'
      else
        echo 'lima smoke check failed'
        return 1
      fi
      USER=nix $out/bin/limactl validate templates/default.yaml
    '';
    patches = (old.patches or []) ++ [
      (prev.writeText "lima-version-override.patch" ''
diff --git a/Makefile b/Makefile
--- a/Makefile
+++ b/Makefile
@@ -45,7 +45,7 @@

 PACKAGE := github.com/lima-vm/lima

-VERSION := $(shell git describe --match 'v[0-9]*' --dirty='.m' --always --tags)
+VERSION ?= $(shell git describe --match 'v[0-9]*' --dirty='.m' --always --tags)
 VERSION_TRIMMED := $(VERSION:v%=%)

 KEEP_SYMBOLS ?=
      '')
    ];
    meta = old.meta // {
      platforms = [ "aarch64-darwin" ];
    };
  });
}
