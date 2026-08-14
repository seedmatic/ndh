# Darwin-common: every macOS host mounts a volatile case-sensitive tmpfs as
# $TMPDIR via the shared home-manager module. Lives in modules/darwin/ so it
# loads on all darwin hosts and never on NixOS — no platform guard needed, no
# per-host duplication. A host can opt out with `services.tmpdirTmpfs.enable`.
{
  ...
}:
{
  hm.imports = [
    {
      imports = [ ../home-manager/tmpdir-tmpfs.nix ];
      services.tmpdirTmpfs.enable = true;
    }
  ];
}
