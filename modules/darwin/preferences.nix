{ config, lib, pkgs, ... }: {
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

      # firewall settings
      alf = {
        # 0 = disabled 1 = enabled 2 = blocks all connections except for essential services
        globalstate = 1;
        loggingenabled = 0;
        # Disable stealth mode to allow mDNS/Bonjour discovery on local network
        stealthenabled = 0;
        allowdownloadsignedenabled = 0;
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
        mru-spaces = false;
      };

      # launcher
      LaunchServices = {
        #  Whether to enable quarantine for downloaded applications.
        LSQuarantine = false;
      };

      # darwin updates
      SoftwareUpdate = { AutomaticallyInstallMacOSUpdates = true; };

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

    # Workaround for setting DNS servers on macOS
    system.activationScripts.postActivation.text = ''
      : "Set DNS servers - only configure specific interfaces if they exist"
      preferred_dns="${builtins.concatStringsSep " " config.networking.dns}"

      services_list=$(networksetup -listallnetworkservices | sed '1d;s/^\*//')

      get_device_for_service() {
        service="$1"
        networksetup -listallhardwareports | awk -v svc="$service" '
          $0 ~ "^Hardware Port: " svc "$" {
            getline
            if ($0 ~ /^Device: /) {
              sub(/^Device: /, "", $0)
              print $0
              exit
            }
          }
        '
      }

      get_dhcp_dns_servers() {
        device="$1"
        if [ -z "$device" ]; then
          return
        fi
        ipconfig getpacket "$device" 2>/dev/null | awk '
          BEGIN { servers = "" }
          /domain_name_server/ {
            sub(/.*= /, "", $0)
            gsub(/[{}]/, "", $0)
            gsub(/,/, " ", $0)
            gsub(/  +/, " ", $0)
            servers = servers " " $0
          }
          END {
            if (servers != "") {
              gsub(/^ +| +$/, "", servers)
              print servers
            }
          }
        '
      }

      for iface in ${lib.concatMapStringsSep " " lib.escapeShellArg config.networking.knownNetworkServices}; do
        if printf '%s\n' "$services_list" | grep -Fxq "$iface"; then
          : "Configuring DNS for interface: $iface"
          device="$(get_device_for_service "$iface")"
          if [ -z "$device" ]; then
            : "No hardware device found for $iface, skipping"
            continue
          fi
          dhcp_servers="$(get_dhcp_dns_servers "$device")"
          combined=""
          for srv in $preferred_dns $dhcp_servers; do
            [ -n "$srv" ] || continue
            case " $combined " in
              *" $srv "*) ;;
              *) combined="$combined $srv" ;;
            esac
          done
          combined="$(printf '%s\n' "$combined" | awk 'NF { $1=$1; print }')"
          if [ -n "$combined" ]; then
            # shellcheck disable=SC2086
            set -- $combined
            networksetup -setdnsservers "$iface" "$@" 2>/dev/null || true
          else
            : "No DNS servers determined for $iface"
          fi
          # Search domains removed - Tailscale/Headscale MagicDNS handles *.ts.net automatically
        else
          : "Interface $iface not found or disabled, skipping DNS configuration"
        fi
      done
    '';
  };
}
