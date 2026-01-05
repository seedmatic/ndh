{
  config,
  lib,
  pkgs,
  ...
}:
let
  preferredDnsString = builtins.concatStringsSep " " config.networking.dns;
  preferredServicesLiteral = lib.concatMapStringsSep " " (
    svc: lib.escapeShellArg svc
  ) config.networking.knownNetworkServices;
  wallpaperImage = ../home-manager/pictures.d/WallPaper.jpg;
  timeoutExe = lib.getExe' pkgs.coreutils "timeout";
  gtimeoutExe = lib.getExe' pkgs.coreutils "gtimeout";
  networkPreferencesScript = pkgs.runCommand "darwin-network-preferences.sh" { } ''
    cp ${
      pkgs.replaceVars ./preferences.d/network-preferences.sh {
        preferredDnsString = preferredDnsString;
        preferredServicesLiteral = preferredServicesLiteral;
      }
    } "$out"
    chmod +x "$out"
  '';

  preferencesPostActivation = pkgs.runCommand "preferences-post-activation.sh" { } ''
    cp ${
      pkgs.replaceVars ./preferences.d/post-activation.sh {
        networkPreferencesScript = networkPreferencesScript;
        timeoutExe = timeoutExe;
        gtimeoutExe = gtimeoutExe;
        wallpaperImage = wallpaperImage;
        activationLogger = lib.attrByPath [
          "activation"
          "loggerScript"
        ] ../common/activation-logger.sh config;
      }
    } "$out"
    chmod +x "$out"
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
  };
}
