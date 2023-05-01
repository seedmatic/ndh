#!/usr/bin/env zsh


local -A _versions=( ${(@f)$(<tool-versions)} )

local _plugin
local _version

for _plugin _version in ${(kv)_versions}; do
    asdf plugin add ${_plugin}
    asdf install $_plugin $_version
done
