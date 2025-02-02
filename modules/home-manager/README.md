## LaunchAgents Logging

To enable logging for LaunchAgents, follow these steps:

1. Open a terminal and run the following command to enable debug mode and redirect stdout and stderr:

    ```sh
    sudo launchctl debug gui/$UID/org.nix-community.home.ssh-add-keys --stdout --stderr
    ```

2. In another terminal, start the LaunchAgent:

    ```sh
    launchctl start org.nix-community.home.ssh-add-keys
    ```