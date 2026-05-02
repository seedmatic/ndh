{
  config,
  lib,
  pkgs,
  ndh,
  ...
}:
let
  ndhContext = ndh.context;
  nixBashTrampoline = "${ndhContext.nixBashTrampoline}";
  preferredDnsString = builtins.concatStringsSep " " config.networking.dns;
  preferredServicesLiteral = lib.concatMapStringsSep " " (
    svc: lib.escapeShellArg svc
  ) config.networking.knownNetworkServices;
  wallpaperImage = config.profile.darwin.wallpaperImage;
  loggerScript = config.nixBashLogger.script;
  timeoutExe = lib.getExe' pkgs.coreutils "timeout";
  gtimeoutExe = lib.getExe' pkgs.coreutils "gtimeout";
  networkPreferencesScript = ndh.store.installScript {
    name = "darwin-network-preferences.sh";
    source = pkgs.replaceVars ./preferences.d/network-preferences.sh {
      preferredDnsString = preferredDnsString;
      preferredServicesLiteral = preferredServicesLiteral;
    };
    preferLocalBuild = true;
    allowSubstitutes = false;
    mode = "0755";
  };

  preferencesPostActivation = ndh.store.installScript {
    name = "preferences-post-activation.sh";
    source = pkgs.replaceVars ./preferences.d/post-activation.sh {
      nixBashTrampoline = nixBashTrampoline;
      networkPreferencesScript = networkPreferencesScript;
      timeoutExe = timeoutExe;
      gtimeoutExe = gtimeoutExe;
      wallpaperImage = wallpaperImage;
    };
    preferLocalBuild = true;
    allowSubstitutes = false;
    mode = "0755";
  };

  osOnlyUpdateNotifierScript = ndh.store.writeShellScriptBin "darwin-os-only-update-notifier" ''
        set -euo pipefail

        update_output="$(${lib.escapeShellArg "/usr/sbin/softwareupdate"} --list --product-types macOS 2>&1 || true)"
        if ! printf '%s\n' "$update_output" | ${lib.escapeShellArg "/usr/bin/grep"} -qE '^\* Label:'; then
          exit 0
        fi

        first_label="$(printf '%s\n' "$update_output" | ${lib.escapeShellArg "/usr/bin/sed"} -n 's/^\* Label: //p' | ${lib.escapeShellArg "/usr/bin/head"} -n1)"
        safe_label="$(printf '%s' "$first_label" | ${lib.escapeShellArg "/usr/bin/tr"} '"' "'")"

        ${lib.escapeShellArg "/usr/bin/osascript"} <<EOF
    display notification "Open System Settings → General → Software Update" with title "macOS updates available" subtitle "$safe_label"
    EOF
  '';
in
{
  config = {
    system.defaults = {
      # login window settings
      loginwindow = {
        # disable guest account
        GuestEnabled = false;
        # show name instead of username
        SHOWFULLNAME = false;
      };

      # file viewer settings
      finder = {
        ShowPathbar = true;
        CreateDesktop = false;
        QuitMenuItem = true;
        AppleShowAllExtensions = true;
        #      FXDefautSearchScope = "SCcf";
        FXPreferredViewStyle = "Nlsv";
        FXEnableExtensionChangeWarning = false;
        _FXShowPosixPathInTitle = true;
      };

      # trackpad settings
      trackpad = {
        # silent clicking = 0, default = 1
        ActuationStrength = 1;
        # enable tap to click
        Clicking = true;
        # firmness level, 0 = lightest, 2 = heaviest
        FirstClickThreshold = 1;
        # firmness level for force touch
        SecondClickThreshold = 1;
        # don't allow positional right click
        TrackpadRightClick = true;
        # three finger drag for space switching
        TrackpadThreeFingerDrag = true;
      };

      # dock settings
      dock = {
        # auto show and hide dock
        autohide = false;
        # remove delay for showing dock
        autohide-delay = 0.0;
        # how fast is the dock showing animation
        autohide-time-modifier = 1.0;
        launchanim = false;
        static-only = false;
        tilesize = 50;
        showhidden = true;
        show-recents = false;
        show-process-indicators = true;
        orientation = "right";
        mru-spaces = true;
      };

      # launcher
      LaunchServices = {
        #  Whether to enable quarantine for downloaded applications.
        LSQuarantine = false;
      };

      # darwin updates
      SoftwareUpdate = {
        # Do not auto-install updates
        AutomaticallyInstallMacOSUpdates = false;
      };

      # Keep Software Update quiet; weekly OS-only checks are handled by launchd.
      CustomUserPreferences."com.apple.SoftwareUpdate" = {
        AutomaticCheckEnabled = false;
        AutomaticDownload = false;
        AutomaticallyInstallMacOSUpdates = false;
      };

      # univesal access
      # should investigate if really needed, error with default write

      # universalaccess = {
      #   closeViewScrollWheelToggle = true;
      #   closeViewZoomFollowsFocus = true;
      # };

      NSGlobalDomain = {
        "com.apple.sound.beep.feedback" = 0;
        "com.apple.sound.beep.volume" = 0.0;
        "com.apple.mouse.tapBehavior" = 1;
        # allow key repeat
        ApplePressAndHoldEnabled = false;
        # delay before repeating keystrokes
        InitialKeyRepeat = 20;
        # delay between repeated keystrokes upon holding a key
        KeyRepeat = 1;
        # display
        _HIHideMenuBar = false;
        AppleShowAllFiles = true;
        AppleShowAllExtensions = true;
        AppleShowScrollBars = "Automatic";
        # input helpers
        NSAutomaticCapitalizationEnabled = false;
        NSAutomaticDashSubstitutionEnabled = false;
        NSAutomaticPeriodSubstitutionEnabled = false;
        NSAutomaticQuoteSubstitutionEnabled = false;
        NSAutomaticSpellingCorrectionEnabled = false;
        NSDisableAutomaticTermination = false;
        NSDocumentSaveNewDocumentsToCloud = false;
        NSTextShowsControlCharacters = true;
      };
    };

    system.keyboard = {
      enableKeyMapping = true;
      remapCapsLockToControl = true;
    };

    networking.applicationFirewall = {
      enable = true;
      blockAllIncoming = false;
      enableStealthMode = false;
      allowSignedApp = false;
    };
    # Run via postActivation so it appears in the main activation script execution list
    system.activationScripts.defaults.text = lib.mkAfter ''
      ${preferencesPostActivation}
    '';

    launchd.user.agents.nxmatic-os-only-softwareupdate-notifier = {
      serviceConfig = {
        Label = "com.nxmatic.softwareupdate.os-only.notifier";
        ProgramArguments = [ "${osOnlyUpdateNotifierScript}/bin/darwin-os-only-update-notifier" ];
        StartCalendarInterval = {
          Weekday = 1;
          Hour = 9;
          Minute = 0;
        };
        ProcessType = "Background";
        RunAtLoad = false;
      };
    };
  };
}
