# What ndh-store runs with, one list for the wrapper and its bats: the suite puts exactly `tools` on the program's
# path, stubs standing in for `system`, so a tool missing here fails a test instead of skipping a check live.
{ pkgs }:
{
  tools = with pkgs; [
    attr
    coreutils
    findutils
    getent
    gnugrep
    gnused
    jq
    procps
    util-linux
  ];
  # The machine's own: stubbed in the suite.
  system =
    {
      nix,
      zfs,
      systemd,
      incus ? null,
    }:
    [
      nix
      zfs
      systemd
    ]
    ++ pkgs.lib.optional (incus != null) incus;
}
