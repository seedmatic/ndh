{
  lib,
  ndh,
  ...
}:
let
  ndhContext = ndh.context;
  effectiveVmProvider = ndhContext.vmProvider;

  # Tart fronts the guest with a dedicated boot disk at /dev/vda — the
  # bringup image uses `mkBootDisk` at build time to lay down an
  # `esp-boot`-labelled 600 MiB disk for the bootstrap
  # closure.  Either way the four ZFS pool disks start at /dev/vdb;
  # declaring `boot = "/dev/vda"` here makes disko emit the
  # `/boot` fileSystems entry (via mkBootDisk) so systemd-boot's
  # post-install mount succeeds on the full config.
  providerDataDisks = {
    boot = "/dev/vda";
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
    # rke2lab's dataplan → the tank/rke2lab/* subtree materialised on the host pool.
    datasetLayout = ndhContext.catalog.datasets;
  };
}
