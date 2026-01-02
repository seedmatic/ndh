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
  networkPreferencesScript = pkgs.writeTextFile {
    name = "darwin-network-preferences.sh";
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      LOG="/var/log/darwin-network-preferences.log"
      mkdir -p "$(dirname "$LOG")"
      touch "$LOG"

      {
        echo "[$(date)] Starting network preferences activation"

        preferred_dns="${preferredDnsString}"

        services_list=()
        while IFS= read -r svc; do
          [ -n "$svc" ] || continue
          services_list+=("$svc")
        done < <(networksetup -listallnetworkservices | sed '1d;s/^\*//')

        service_exists() {
          local target="$1"
          local entry
          for entry in "''${services_list[@]}"; do
            if [ "$entry" = "$target" ]; then
              return 0
            fi
          done
          return 1
        }

        ordered_services=()
        append_service() {
          local svc="$1"
          local existing
          for existing in "''${ordered_services[@]}"; do
            if [ "$existing" = "$svc" ]; then
              return
            fi
          done
          ordered_services+=("$svc")
        }

        preferred_services=( ${preferredServicesLiteral} )

        for iface in "''${preferred_services[@]}"; do
          if service_exists "$iface"; then
            append_service "$iface"
          else
            echo "Preferred service $iface not present; skipping ordering preference"
          fi
        done

        for svc in "''${services_list[@]}"; do
          append_service "$svc"
        done

        if [ "''${#ordered_services[@]}" -gt 0 ]; then
          if networksetup -ordernetworkservices "''${ordered_services[@]}" >/dev/null 2>&1; then
            echo "Applied service order: ''${ordered_services[*]}"
          else
            echo "Warning: networksetup -ordernetworkservices failed"
          fi
        fi

        get_device_for_service() {
          local service="$1"
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
          local device="$1"
          if [ -z "$device" ]; then
            return
          fi
          ipconfig getpacket "$device" 2>/dev/null | awk '
            /domain_name_server/ {
              sub(/.*: */, "", $0)
              gsub(/[{}]/, "", $0)
              gsub(/,/, " ", $0)
              gsub(/  +/, " ", $0)
              printf "%s ", $0
            }
          ' | awk 'NF { $1=$1; print }'
        }

        for iface in "''${preferred_services[@]}"; do
          if ! service_exists "$iface"; then
            continue
          fi
          echo "Configuring DNS for interface: $iface"
          device="$(get_device_for_service "$iface")"
          if [ -z "$device" ]; then
            echo "No hardware device found for $iface, skipping"
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
            IFS=' ' read -r -a dns_array <<<"$combined"
            if networksetup -setdnsservers "$iface" "''${dns_array[@]}" >/dev/null 2>&1; then
              echo "Set DNS for $iface -> $combined"
            else
              echo "Warning: failed to set DNS servers for $iface"
            fi
          else
            echo "No DNS servers determined for $iface"
          fi
        done

        echo "[$(date)] Network preferences activation complete"
      } >>"$LOG" 2>&1
    '';
  };

  preferencesPostActivation = pkgs.runCommand "preferences-post-activation.sh" { } ''
    cp ${
      pkgs.replaceVars ./preferences.d/post-activation.sh {
        networkPreferencesScript = networkPreferencesScript;
        timeoutExe = timeoutExe;
        gtimeoutExe = gtimeoutExe;
        wallpaperImage = wallpaperImage;
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
    system.activationScripts.postActivation.text = lib.mkAfter ''
      ${preferencesPostActivation}
    '';
  };
}
