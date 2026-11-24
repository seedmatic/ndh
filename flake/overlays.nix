{ inputs }:
{
  channels = inputs: final: prev: {
    nixpkgs = import inputs.nixpkgs {
      system = prev.stdenv.hostPlatform.system;
    };
  };

  extraPackages =
    inputs: final: prev:
    let
      hostSystem = prev.stdenv.hostPlatform.system;
    in
    {
      #inherit (self.packages.${hostSystem}) sysdo pyEnv;

      # rancher-desktop = final.callPackage ../pkgs/rancher-desktop.nix {};
      browseros-neo = final.callPackage ../pkgs/browseros-neo.nix { };
      tart-guest-agent = final.callPackage ../pkgs/tart-guest-agent.nix { };
      inherit (inputs.maven-mvnd.packages.${hostSystem}) maven-mvnd-m39;
      inherit (inputs.disko.packages.${hostSystem}) disko;
      flox = inputs.flox.packages.${hostSystem}.default;
    };

  qemuOverlay = inputs: import ../overlays/qemu.nix inputs;
  incusOverlay = inputs: import ../overlays/incus.nix inputs;
  lazygitOverlay = inputs: import ../overlays/lazygit.nix inputs;
  tailscaleOverlay = inputs: import ../overlays/tailscale.nix inputs;
  vmToolsDeterministicOverlay = inputs: import ../overlays/vm-tools-deterministic.nix inputs;

  # Overlay to disable tests for a2a-sdk package that causes permission errors during build
  python313Overlay = inputs: import ../overlays/python313.nix inputs;

  # Expose omo-ai from numtide/llm-agents.nix (via flake-commons).
  omoAiOverlay = inputs: final: prev: {
    omo-ai = inputs.llm-agents.packages.${final.stdenv.hostPlatform.system}.omo-ai;
  };

  # Use the newer llama-cpp from nixpkgs-unstable, which includes the fix
  # for unanchored JSON Schema `pattern` fields in tool-calling requests
  # (ggml-org/llama.cpp#26930, closed in PR #26939).  The pinned nixpkgs
  # ships 9190, which rejects those patterns and breaks tool calling.
  llamaCppOverlay = inputs: final: prev: {
    llama-cpp =
      (import inputs.nixpkgs-unstable {
        system = final.stdenv.hostPlatform.system;
        config = {
          allowBroken = true;
          checkAllPackages = false;
        };
      }).llama-cpp;
  };

  direnvOverlay = _inputs: final: prev: {
    # Upstream direnv fish tests are intermittently SIGKILLed on this build fleet.
    # Keep runtime package deterministic by disabling checks in the canonical overlay path.
    direnv = prev.direnv.overrideAttrs (old: {
      doCheck = false;
      dontCheck = true;
      checkPhase = "echo skipping direnv checkPhase";
      installCheckPhase = "echo skipping direnv installCheckPhase";
      phases = builtins.filter (p: p != "checkPhase" && p != "installCheckPhase") (old.phases or [ ]);
    });
  };
}
