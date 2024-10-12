{...}: {
  home.file.".config/avahi/avahi-daemon.conf".text = ''
    [server]
    host-name=your-hostname
    domain-name=local
    use-ipv4=yes
    use-ipv6=yes
    allow-interfaces=eth0,wlan0
    enable-dbus=yes

    [publish]
    publish-addresses=yes
    publish-hinfo=yes
    publish-workstation=yes
    publish-domain=yes

    [reflector]
    enable-reflector=no

    [rlimits]
    rlimit-core=0
    rlimit-data=4194304
    rlimit-fsize=0
    rlimit-nofile=768
    rlimit-stack=4194304
  '';
}
