# nixpkgs incus 7.4.0's client completion generation runs `incus completion
# <shell>`, which creates and then re-reads an empty ~/.config/incus/config.yml
# and aborts with `Failed to load configuration: yaml: no documents in stream`.
# Upstream's postInstall only `mkdir`s the throwaway config dir (client.nix), so
# the completions come out zero-size and the build fails. Seed a valid empty-doc
# config ({}) in that HOME first. Drop this once nixpkgs fixes incus completions.
#
# The client is `incus.passthru.client` (generic.nix), which ndh consumes as
# `pkgs.incus.passthru.client` (modules/home-manager/incus-remote.nix), so patch
# it through incus's passthru rather than a (non-existent) top-level attr.
inputs: final: prev: {
  incus = prev.incus.overrideAttrs (old: {
    passthru = old.passthru // {
      client = old.passthru.client.overrideAttrs (_: {
        postInstall = ''
          export HOME="$(mktemp -d)"
          mkdir -p "$HOME/.config/incus"
          printf '{}\n' > "$HOME/.config/incus/config.yml"

          installShellCompletion --cmd incus \
            --bash <($out/bin/incus completion bash) \
            --fish <($out/bin/incus completion fish) \
            --zsh <($out/bin/incus completion zsh)
        '';
      });
    };
  });
}
