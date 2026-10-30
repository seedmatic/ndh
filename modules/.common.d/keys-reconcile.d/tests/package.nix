# keys-reconcile's bats suite as a flake check, through the real trampoline and logger (handed over: the sandbox
# cannot search the store for it); a local bare stands for the remote, the seat for the machine.
{ pkgs, trampoline }:
pkgs.runCommand "keys-reconcile-bats"
  {
    nativeBuildInputs = with pkgs; [
      age
      bats
      bash
      check-jsonschema
      coreutils
      gawk
      findutils
      git
      gnugrep
      gnused
      hostname
      openssh
      sops
      ssh-to-age
      yq-go
    ];
    NDH_TRAMPOLINE = trampoline;
    KEYS_SCHEMA = ../../../home-manager/ssh.d/keys.schema.yaml;
    NDH_BOOTSTRAP_PROFILE_DIR = import ../../shell.d/tests/bootstrap-profile.nix { inherit pkgs; };
  }
  ''
    cp -r ${./..} keys-reconcile.d && cp -r ${../../keys-yaml.d} keys-yaml.d && chmod -R u+w keys-reconcile.d keys-yaml.d
    cd keys-reconcile.d/tests && HOME=$TMPDIR bats --print-output-on-failure .
    touch $out
  ''
