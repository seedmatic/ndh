# The tools a script ndh runs may take from its OWN PATH instead of the bringup profile: the reviewed exception
# list (operator, 2026-10-22). Every other CLI a script needs goes into the profile. Each entry is a tool one to
# three programs use, too heavy or too platform-bound to copy into every machine's profile (vector, qemu, python3
# would land on each vz-host). The trampoline-entry check (batch 2.6) refuses a private PATH that names anything
# else; a new entry is reviewed like the parse exemptions, one reason each.
{
  vector = {
    programs = [ "nix-build-observe" ];
    reason = "the build observer's log shipper; only the seats observing a build run it";
  };
  godns = {
    programs = [ "godns-launcher" ];
    reason = "the DDNS agent of the darwin seats, one launchd job";
  };
  headscale = {
    programs = [
      "hs"
      "headscale-bootstrap-launcher"
    ];
    reason = "the tailnet control plane's own CLI, pinned to the daemon's version on the hosts that run it";
  };
  tailscale = {
    programs = [
      "hs-status"
      "hs-ssh"
      "hs-connect"
      "hs-disconnect"
      "headscale-gateway-status"
    ];
    reason = "the tailnet client the system already runs as a service; its CLI comes with it";
  };
  gh = {
    programs = [
      "darwin-rebuild-gh"
      "nixos-rebuild-gh"
    ];
    reason = "the GitHub CLI, for the two rebuild-from-a-PR helpers only";
  };
  qemu = {
    programs = [ "ndh-ceremony-vm" ];
    reason = "the ceremony VM's hypervisor: a seat app run at the root ceremony only";
  };
  mtools = {
    programs = [ "ndh-ceremony-vm" ];
    reason = "writes the ceremony VM's FAT drive; the same single program";
  };
  check-jsonschema = {
    programs = [ "ssh-keys-v2-validate" ];
    reason = "a python validator for keys.yaml's schema, run by hand";
  };
  python3 = {
    programs = [
      "github-mcp-proxy"
      "ndh-keyring-gen-ed25519"
    ];
    reason = "two python programs: the MCP proxy, and the ed25519 generator (porting it is open, batch 2 review)";
  };
}
