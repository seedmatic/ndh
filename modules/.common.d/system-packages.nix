{ pkgs, ... }:
with pkgs;
[
  bash
  coreutils-full
  direnv
  git
  gitflow
  emacs-nox
  remake
  powerline-fonts
  powerline-go
  powerline-symbols
  ripvcs
  sops
  ssh-to-age
  # step-cli is consumed by the SSH enrichment pipeline to mint x509
  # TLS leaf certs off the shared `mammoth-skate` authority (see
  # modules/.common.d/ssh-keys.d/ssh-enrich-keys-yaml.sh's
  # sign::tls_server).  Dormant when no key declares
  # `cert_usage: [tls-server]`.
  step-cli
  yq-go
  zsh
]
