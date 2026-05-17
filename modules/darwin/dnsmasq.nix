{
  pkgs,
  ...
}:
{
  # Run dnsmasq as a per-user LaunchAgent (not a LaunchDaemon) so the
  # process lives under the primary user's session on an unprivileged
  # port (see modules/.common.d/dnsmasq.nix `port=5354`).  Consumers
  # reach it via /etc/resolver/<zone> with an explicit `port 5354` line.
  #
  # Trade-off: a LaunchAgent only runs while the user has an active
  # session.  Acceptable here — *.mammoth-skate.test resolution is only
  # needed when the user is actually using the machine.
  launchd.user.agents.dnsmasq = {
    serviceConfig = {
      Label = "io.nxmatic.nix-darwin-home.darwin.dnsmasq";
      ProgramArguments = [
        "${pkgs.dnsmasq}/bin/dnsmasq"
        "--conf-file=/etc/dnsmasq.conf"
        "--keep-in-foreground"
        # No --log-facility: dnsmasq's default is syslog, which macOS
        # bridges into unified logging.  Inspect with:
        #   log show --predicate 'process == "dnsmasq"' --last 1h
        #   log stream --predicate 'process == "dnsmasq"'
        # (Symbolic facility names like LOG_DAEMON aren't recognized
        # by the nixpkgs dnsmasq build on Darwin → "bad log facility".)
      ];
      RunAtLoad = true;
      KeepAlive = true;

      # Auto-restart on config change.  On every darwin-rebuild switch
      # that alters the rendered `/etc/dnsmasq.conf` (or the addn-hosts
      # file the conf references by store path), nix-darwin atomically
      # swaps `/etc/static`, which changes the resolved inode behind
      # `/etc/dnsmasq.conf`.  launchd's kqueue watcher fires a vnode
      # event on the swap and bounces the daemon, so the new zone
      # records / cname aliases / forwarders take effect without a
      # manual `launchctl kickstart -k`.
      #
      # Only one path needed: addn-hosts changes flow through the
      # main conf because it's referenced by a store-path-pinned
      # absolute name (the conf string itself differs when the
      # addn-hosts content differs → conf store path differs → vnode
      # event fires).
      WatchPaths = [ "/etc/dnsmasq.conf" ];
    };
  };
}
