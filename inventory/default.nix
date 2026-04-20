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
        form = "baremetal";
        networks = [
          "lan"
          "tailnet"
        ];
        vm = {
          kind = "vz";
          manager = "lima";
        };
        builder = {
          systems = [ "aarch64-linux" ];
          maxJobs = 8;
          protocol = "ssh-ng";
          vmCpuCores = 8;
          vmMemoryMiB = 24576;
        };
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
      {
        form = "vm";
        networks = [
          "lan"
          "tailnet"
        ];
        vm = {
          kind = "vz";
          manager = "lima";
        };
        builder = {
          systems = [ "aarch64-linux" ];
          maxJobs = 8;
          protocol = "ssh-ng";
        };
      }
    ];
  };
}
