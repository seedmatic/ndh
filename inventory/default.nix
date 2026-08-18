{
  hosts = {
    bioskop = [
      {
        form = "baremetal";
        networks = [
          "lan"
          "tailnet"
        ];
        builder = {
          systems = [ "aarch64-darwin" ];
          maxJobs = 8;
          protocol = "ssh-ng";
        };
      }
      {
        form = "baremetal";
        networks = [
          "lan"
          "tailnet"
        ];
        vm = {
          kind = "qemu";
          manager = "nix-darwin";
        };
        builder = {
          systems = [ "aarch64-linux" ];
          maxJobs = 8;
          protocol = "ssh-ng";
          vmCpuCores = 8;
          vmMemoryMiB = 24576;
        };
      }
      {
        # nerd-nixos: NixOS VM running as a Tart/VZ VM on bioskop
        form = "baremetal";
        networks = [
          "lan"
          "tailnet"
        ];
        vm = {
          kind = "vz";
          manager = "tart";
        };
        builder = null;
      }
    ];

    nikopol = [
      {
        # nikopol runs as a Tart/VZ macOS VM and does NOT serve as a darwin builder itself; it offloads to remote builders
        form = "vm";
        networks = [
          "lan"
          "tailnet"
        ];
        vm = {
          kind = "vz";
          manager = "tart";
        };
        builder = null;
      }
    ];
  };
}
