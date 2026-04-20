#!@bash@
set -euo pipefail

# Installer bootstrap mode: profile may not exist yet.
export NDH_BOOTSTRAP_STRICT=0
# shellcheck disable=SC1091
source "@logger@"

main() {
  local autofs_materializer="@autofsMaterializerProgram@"

  if [[ -n "${autofs_materializer}" ]]; then
    /usr/bin/sudo "${autofs_materializer}"
  fi

  exec "@standaloneInstaller@" "$@"
}

ndh::logger:command:run "@loggerTag@" main "$@"
