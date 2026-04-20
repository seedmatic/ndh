{
  lib,
  ndh,
  ...
}:
let
  ndhContext = ndh.context;
  effectiveVmProvider = ndhContext.vmProvider;

  providerDataDisks =
    if effectiveVmProvider == "tart" then
      {
        tank1 = "/dev/vda";
        tank2 = "/dev/vdb";
        tank3 = "/dev/vdc";
        recover = "/dev/vdd";
      }
    else
      {
        # Lima keeps bootstrap/root as /dev/vda; ZFS data disks are attached after it.
        tank1 = "/dev/vdb";
        tank2 = "/dev/vdc";
        tank3 = "/dev/vdd";
        recover = "/dev/vde";
      };
in
{
  disko = import ./zfs-disko-config.nix {
    inherit lib;
    hostProfile = ndhContext.hostProfile;
    disks = providerDataDisks;
  };
}
