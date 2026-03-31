## LaunchAgents Logging

To enable logging for LaunchAgents, follow these steps:

1. Open a terminal and run the following command to enable debug mode and redirect stdout and stderr:

    ```sh
    sudo launchctl debug gui/$UID/io.nxmatic.nix-darwin-home.home.ssh-add-keys --stdout --stderr
    ```

2. In another terminal, start the LaunchAgent:

    ```sh
    launchctl start io.nxmatic.nix-darwin-home.home.ssh-add-keys
    ```