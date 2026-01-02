inputs: final: prev: {
  qemu-pkgdb = prev.qemu.overrideAttrs (oldAttrs: {
    patches = (oldAttrs.patches or [ ]) ++ [
      ./qemu/0001-PATCH-hvf-arm-disable-SME-which-is-not-properly-hand.patch
    ];
    prePatch = ''
      ${oldAttrs.prePatch or ""}
    '';
    postPatch = ''
      ${oldAttrs.postPatch or ""}
    '';
    postUnpack = ''
      ${oldAttrs.postUnpack or ""}
    '';
  });
}
