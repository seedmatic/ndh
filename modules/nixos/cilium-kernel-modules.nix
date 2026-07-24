# Cilium kernel modules configuration (@codebase)
# This module loads kernel modules required by Cilium CNI in RKE2/K8s clusters

{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Kernel modules required by Cilium for:
  # - ip_set: IPSet support for node IP tracking (required by kubeProxyReplacement)
  # - ip_set_hash_ip: Hash:IP type for IP sets
  # - xt_set: iptables set matching support
  # - nf_conntrack: Connection tracking (required for NAT and service routing)
  # - nft_nat: nftables NAT support (optional but recommended)
  # - nft_fib_inet: nftables FIB expressions for the inet family (reverse-path checks)
  # - nft_reject_inet: nftables reject verdict for the inet family
  boot.kernelModules = [
    "ip_set"
    "ip_set_hash_ip"
    "ip_set_hash_net"
    "xt_set"
    "nf_conntrack"
    "nft_nat"
    "nft_fib_inet"
    "nft_reject_inet"
  ];

  # Ensure ipset userspace tools are available for debugging
  environment.systemPackages = with pkgs; [
    ipset
  ];
}
