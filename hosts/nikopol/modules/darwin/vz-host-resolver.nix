# Per-host bridge: imports the home-manager-scope vz-host-resolver
# module on nikopol only.  Lives in modules/darwin/ so the host-name
# guard fires at system-config evaluation; the actual resolver +
# ssh-config + package install all happen in the home-manager scope
# at hosts/nikopol/modules/home-manager/vz-host-resolver.nix.
#
# Why split:
#   - `home.packages` lives in HM scope so the resolver lands in the
#     operator's user nix-profile (~/.nix-profile/bin/<binName>),
#     which is where the SSH ProxyCommand expects it.  Setting
#     `hm.home.packages` from a Darwin module did not bridge cleanly
#     to the on-disk profile on this fleet — `home.packages`
#     declared from a HM-scope module did, so we follow that
#     pattern.
#   - The host guard is applied here at the Darwin layer because
#     `config.profile.host.hostName` is a system-config option;
#     wiring `hm.imports` conditionally is the simplest way to
#     restrict the HM module to this host without sprinkling the
#     guard inside HM-scope.
{
  config,
  lib,
  ...
}:
{
  hm.imports =
    lib.optional (config.profile.host.hostName == "nikopol")
      ../home-manager/vz-host-resolver.nix;
}
