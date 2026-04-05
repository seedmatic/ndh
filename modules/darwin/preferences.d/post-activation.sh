#!/usr/bin/env -S bash -euo pipefail
source @logger@

main() {
  @networkPreferencesScript@

  # Disable Siri and Spotlight shortcuts, and the Ctrl+Space input switcher
  /usr/bin/defaults write com.apple.assistant.support "Assistant Enabled" -bool false
  /usr/bin/defaults write com.apple.Siri StatusMenuVisible -bool false
  /usr/bin/defaults write com.apple.Siri VoiceTriggerUserEnabled -bool false
  /bin/launchctl disable gui/$UID/com.apple.Siri.agent || true

  # Disable Spotlight search shortcuts (64,65) and input source switchers (60,61)
  /usr/bin/defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 60 "{enabled = 0;}"
  /usr/bin/defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 61 "{enabled = 0;}"
  /usr/bin/defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 64 "{enabled = 0;}"
  /usr/bin/defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 65 "{enabled = 0;}"

  # Kick cfprefsd so changes are read
  /usr/bin/killall cfprefsd || true

  # Set desktop wallpaper from repo-managed image using the console user's session; guard and timeout to avoid hangs
  set_wallpaper() {
    local wallpaper="$1"
    local console_user
    console_user=$(/usr/bin/stat -f %Su /dev/console 2>/dev/null || true)
    if [ -z "$console_user" ] || [ "$console_user" = "root" ]; then
      return 0
    fi

    local console_uid
    console_uid=$(/usr/bin/id -u "$console_user" 2>/dev/null || true)
    if [ -z "$console_uid" ]; then
      return 0
    fi

    local -a cmd=(
      /bin/launchctl asuser "$console_uid" /usr/bin/osascript -e
      "tell application \"System Events\" to set picture of every desktop to POSIX file \"$wallpaper\""
    )

    local timeout_bin="@timeoutExe@"
    local gtimeout_bin="@gtimeoutExe@"
    if [ -x "$timeout_bin" ]; then
      "$timeout_bin" 10 "${cmd[@]}" || true
    elif [ -x "$gtimeout_bin" ]; then
      "$gtimeout_bin" 10 "${cmd[@]}" || true
    else
      /usr/bin/perl -e 'alarm 10; exec @ARGV' "${cmd[@]}" || true
    fi
  }

  set_wallpaper "@wallpaperImage@" || true
}

ndh::logger:command:run darwin.activationScripts.defaults.preferences main "$@"
