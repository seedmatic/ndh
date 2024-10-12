#!/usr/bin/env -S bash -xe -o pipefail

: Remove the _avahi user
dscl . -delete /Users/avahi

: Remove the _avahi group
dscl . -delete /Groups/avahi

: Create the new avahi user
dscl . -create /Users/avahi
dscl . -create /Users/avahi UserShell /usr/bin/false
dscl . -create /Users/avahi RealName "Avahi Daemon"
dscl . -create /Users/avahi UniqueID 10201
dscl . -create /Users/avahi PrimaryGroupID 10201
dscl . -create /Users/avahi NFSHomeDirectory /var/empty
dscl . -create /Users/avahi IsHidden 1

: Create the new avahi group
dscl . -create /Groups/avahi
dscl . -create /Groups/avahi PrimaryGroupID 10201
dscl . -create /Groups/avahi RealName "Avahi Daemon"

: Add the avahi user to the avahi group
dscl . -append /Groups/avahi GroupMembership avahi
