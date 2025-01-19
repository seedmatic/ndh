inputs: final: prev: {
  qemu-pkgdb = prev.qemu.overrideAttrs (oldAttrs: {
    patches = (oldAttrs.patches or [ ]) ++ [
      ./qemu/0001-PATCH-hvf-arm-disable-SME-which-is-not-properly-hand.patch
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
