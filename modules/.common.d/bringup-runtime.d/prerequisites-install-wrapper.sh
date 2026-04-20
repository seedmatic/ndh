#!/usr/bin/env bash
set -euo pipefail

# Installer bootstrap mode: profile may not exist yet.
# shellcheck disable=SC1091
source "@nixBashTrampoline@"

main() {
  local autofs_materializer="@autofsMaterializerProgram@"

  if [[ -n "${autofs_materializer}" ]]; then
    /usr/bin/sudo "${autofs_materializer}"
  fi

  exec "@standaloneInstaller@" "$@"
}

ndh::logger:command:run "@loggerTag@" main "$@"
