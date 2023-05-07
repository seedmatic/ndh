{...}: {
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

    # firewall settings
    alf = {
      # 0 = disabled 1 = enabled 2 = blocks all connections except for essential services
      globalstate = 1;
      loggingenabled = 0;
      stealthenabled = 1;
      allowdownloadsignedenabled = 0;
    };

    # dock settings
    dock = {
      # auto show and hide dock
      autohide = true;
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
      mru-spaces = false;
    };

    # launcher
    LaunchServices = {
      #  Whether to enable quarantine for downloaded applications.
      LSQuarantine = false;
    };

    # darwin updates
    SoftwareUpdate = {
      AutomaticallyInstallMacOSUpdates = true;
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
      InitialKeyRepeat = 10;
      # delay between repeated keystrokes upon holding a key
      KeyRepeat = 1;
      # display
      _HIHideMenuBar = true;
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

}
