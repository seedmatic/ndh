inputs: final: prev: {
  devcontainer-pkgdb = prev.qemu.overrideAttrs (oldAttrs: {
    patches = (oldAttrs.patches or [ ]) ++ [
      ./devcontainer.d/0001-hotfix-options-overrideCommand-option-does-not-corre.patch
    ];
    prePatch = ''
      ${oldAttrs.prePatch or ""}
      echo "Starting prePatch phase"
    '';
    postPatch = ''
      ${oldAttrs.postPatch or ""}
      echo "Starting postPatch phase"
    '';
    postUnpack = ''
      ${oldAttrs.postUnpack or ""}
      echo "Starting postUnpack phase"
    '';
  });
}
