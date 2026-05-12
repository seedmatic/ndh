# Guest-side /etc/nixos/flake.nix wrapper for day-2 nixos-rebuild.
#
# In full runtime mode we write a minimal flake at /etc/nixos/flake.nix that
# forwards inputs + outputs to the git checkout shared into the guest at
# cfg.sourcePath (default /var/lib/git/nxmatic/nix-darwin-home). This lets the
# operator run `nixos-rebuild switch` from inside the VM and pick up new
# commits the operator pushes to that tree — no rebuild of the VM image
# required.
#
# The minimal bringup image does not import this module; it pins
# /etc/nixos → self via environment.etc."nixos".source (see
# bringup-minimal-system.nix).
{
  config,
  lib,
  ndh,
  ...
}:
let
  cfg = config.ndh.etcNixosFlake;
  ndhContext = ndh.context or { };
  guestHostName =
    if config.networking.hostName != null && config.networking.hostName != "" then
      config.networking.hostName
    else
      "host";
  flakeRef = "git+file://${cfg.sourcePath}";
  flakeText = ''
    {
      description = "Forwarding flake for /etc/nixos — inputs/outputs proxy to ${flakeRef}.";
      inputs.nix-darwin-home.url = "${flakeRef}";
      outputs = inputs: inputs.nix-darwin-home.outputs;
    }
  '';
in
{
  options.ndh.etcNixosFlake = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = (ndhContext.generationMode or "full") == "full";
      description = ''
        When true, materialize /etc/nixos/flake.nix as a forwarding wrapper
        that resolves inputs from the git checkout at sourcePath.
      '';
    };
    sourcePath = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/git/nxmatic/nix-darwin-home";
      description = "Guest-side path of the shared git checkout the wrapper forwards to.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."nixos/flake.nix".text = flakeText;
  };
}
