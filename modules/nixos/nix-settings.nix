# NixOS-specific nix daemon configuration: trusted-users, build users, sandbox,
# kvm, auto-optimise. Substituter + trusted-public-key emission lives in
# modules/.common.d/cache-trust.nix (walks the catalog automatically).
{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  cfgUser = config.profile.user;
  cfgUserName = cfgUser.name;

  # Whether this guest has KVM is decided when the VM is LAUNCHED (Tart's --nested, which
  # NESTED_VIRT overrides at runtime), not when it is evaluated. So the evaluated settings never
  # advertise kvm; a boot-time unit states what the running VM actually has, in a file the
  # daemon includes. The Mac's buildMachines line states the INTENT (tart vmRunNestedVirt): a
  # kvm build sent while the override is on fails on this side, loudly, instead of running TCG.
  kvmConf = "/run/ndh/nix-kvm.conf";
  defaultFeatures = (options.nix.settings.type.getSubOptions [ ]).system-features.default;
in
{
  nix.settings = {
    auto-optimise-store = false; # Manual optimise keeps build latency predictable during development.
    trusted-users = [
      cfgUserName
      "root"
    ];
    # Builds run as the nixbldN users. NixOS emits no build-users-group here, so
    # Nix fell back to a default that depends on the daemon's uid; stated, it is
    # a reviewed fact. Nix takes the group's MEMBERS as build users: only the
    # nixbldN accounts may be members: Nix would build as any other member, and kill its
    # processes (an ssh session) before each build.
    build-users-group = "nixbld";
    sandbox = true;
    # mkForce: NixOS DEFINES its feature list (kvm included) rather than defaulting it, so a plain
    # definition would be concatenated to it.
    system-features = lib.mkForce (lib.remove "kvm" defaultFeatures);
  };

  # Only the nixbldN build users may hold build-users-group. The daemon refuses a client whose PRIMARY
  # group it is, trusted or not (daemon.cc, authPeer), and takes the group's MEMBERS as build users
  # (user-lock.cc, getgrnam's gr_mem).
  assertions =
    let
      group = config.nix.settings.build-users-group;
      buildUser = name: builtins.match "nixbld[0-9]+" name != null;
      others = lib.filterAttrs (name: _: !buildUser name) config.users.users;
      primary = lib.attrNames (lib.filterAttrs (_: u: u.group == group) others);
      members = lib.filter (name: !buildUser name) (
        config.users.groups.${group}.members or [ ]
        ++ lib.attrNames (lib.filterAttrs (_: u: lib.elem group u.extraGroups) others)
      );
    in
    [
      {
        assertion = primary == [ ];
        message = "build-users-group '${group}' is the primary group of ${lib.concatStringsSep ", " primary}: the nix daemon refuses them as clients";
      }
      {
        assertion = members == [ ];
        message = "${lib.concatStringsSep ", " members} would be build users: only nixbldN may be members of '${group}'";
      }
    ];

  nix.extraOptions = ''
    !include /etc/nix/nix.custom.conf
    !include ${kvmConf}
  '';

  systemd.services.ndh-nix-kvm-features = {
    description = "State whether this boot has /dev/kvm, for the nix daemon";
    wantedBy = [ "multi-user.target" ];
    before = [ "nix-daemon.service" ];
    requiredBy = [ "nix-daemon.service" ];
    after = [ "systemd-udev-settle.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.coreutils}/bin/mkdir -p ${dirOf kvmConf}
      if [ -c /dev/kvm ]; then
        printf 'extra-system-features = kvm\n' > ${kvmConf}
      else
        : > ${kvmConf}
      fi
    '';
  };

  # systemd's default rule leaves /dev/kvm world-writable (0666). Nix 2.34 mounts /dev/kvm into
  # EVERY sandbox once kvm is among the daemon's features (linux-derivation-builder.cc reads the
  # store's systemFeatures, not the derivation's), but the sandbox drops every supplementary group
  # (setgroups(0, 0)): a build holds only its primary gid, build-users-group. So the kvm group
  # keeps the device, and an ACL opens it to that gid alone — not to a login user. RUN applies it
  # on every event for the node, so a re-trigger or a module reload re-applies it.
  services.udev.extraRules = ''
    KERNEL=="kvm", GROUP="kvm", MODE="0660", RUN+="${pkgs.acl}/bin/setfacl -m g:${config.nix.settings.build-users-group}:rw /dev/kvm"
  '';
}
