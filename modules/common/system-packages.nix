{
  pkgs,
  inputs,
  ...
}:
with pkgs; [
  # nix
  home-manager
  inputs.flox.packages.${pkgs.system}.flox
  nix-du
  nix-index
  nix-tree
  nix-prefetch-git

  # standard toolset
  clang_19
  coreutils-full
  cmake
  curl
  diffutils
  findutils
  getopt
  git
  git-town
  gitAndTools.gitflow
  gnused
  libevent
  pstree
  remake
  wget
  pcre2

  # system build
  autoconf
  automake
  bison
  libtool

  # yaml
  yq-go
  yamllint

  # shells
  #bashInteractive
  fish
  zsh

  # helpful shell stuff
  broot
  #fd
  bat
  fzf
  ripgrep

  # shell debugging
  shellcheck
  # bashdb

  # terminals
  kitty
  kitty-themes
  terminal-notifier
  tmuxinator
  tmux
  tmate # tmux clone for GHA
  tmate-ssh-server
  reattach-to-user-namespace
  zellij # replace byobu (in evaluation)

  # git
  git
  git-workspace
  tig

  # github cli
  actionlint
  gh

  # editors
  neovim
  emacs-nox

  # java
  jdk
  maven
  maven-mvnd-m39
  gradle

  # python
  python3Full
  python3Packages.dnslib

  # ide
  vscode
  openvscode-server

  # web browsing
  #brave (glibc)
  #chromium (rosetta)
  html2text
  #firefox
  w3m

  # social (see brew cask)
  #kbfs
  #keybase
  #keybase-gui

  slack
  zoom-us

  # shell
  powerline-go
  zoxide

  # document viewer
  # zathura

  # knowledge base (need glibc on darwin)
  # obsidian
  # zotero

  # virtual env manager for coding
  direnv
  #lorri

  # macos
  raycast # launcher
  syncthing # volumes synch
  realvnc-vnc-viewer # vnc viewer

  # networking
  dbus
  avahi
  bird
  nmap
  tshark
  dnsmasq
  ipcalc

  # nodejs
  sauce-connect

  # android
  android-tools

  # container runtimes
  buildkit
  docker-client
  docker-credential-gcr
  docker-credential-helpers
  colima
  lima
  qemu
  podman
  podman-compose

  # doc
  graphviz

  # crypto
  gnupg
  #pinentry
  #     pinentry-curses
  #     pinentry_mac

  oath-toolkit

  pass
  passExtensions.pass-audit
  passExtensions.pass-checkup
  passExtensions.pass-otp
  #passExtensions.update
  pass-git-helper
  passff-host

  sops
]
# ++ (if config.zen-browser.enable then config.zen-browser.packages else [])

