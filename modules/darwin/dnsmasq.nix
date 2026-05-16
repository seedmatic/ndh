{
  config,
  lib,
  pkgs,
  ndh,
  ...
}:
let
  ndhContext = ndh.context;
  nixBashTrampoline = "${ndhContext.nixBashTrampoline}";
  user = config.profile.user;
  userName = user.name;
  logFile = "/Users/${userName}/Library/Logs/dnsmasq.log";

  dnsmasqActivationScript = ndh.store.runCommand "dnsmasq-post-activation.sh" { } ''
    cp ${
      pkgs.replaceVars ./dnsmasq.d/post-activation.sh {
        nixBashTrampoline = nixBashTrampoline;
        logFile = logFile;
        userName = userName;
      }
    } "$out"
    chmod +x "$out"
  '';
in
{
  launchd.daemons.dnsmasq = lib.mkForce {
    serviceConfig = {
      Label = "io.nxmatic.nix-darwin-home.darwin.dnsmasq";
      ProgramArguments = [
        "${pkgs.dnsmasq}/bin/dnsmasq"
        "--conf-file=/etc/dnsmasq.conf"
        "--keep-in-foreground"
        "--log-facility=${logFile}"
      ];
      RunAtLoad = false;
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

  system.activationScripts.postActivation.text = lib.mkAfter ''
    ${dnsmasqActivationScript}
  '';
}
