# flox-config's bats suite as a flake check, run against the PACKAGED program (its own runtimeInputs, not the suite's
# tools). A mutant that replaces the file instead of merging one key must fail the suite.
{ pkgs, floxConfig }:
let
  suite = program: ''
    cp -r ${./.} tests && chmod -R u+w tests
    (cd tests && HOME=$TMPDIR FLOX_CONFIG=${program}/bin/flox-config bats --print-output-on-failure .)
  '';
  # Writes only the declared keys: the operator's hand-kept ones would be lost.
  replacing = pkgs.writeShellApplication {
    name = "flox-config";
    runtimeInputs = with pkgs; [
      coreutils
      yq-go
    ];
    text = ''
      file="$1"
      shift
      mkdir -p "$(dirname "$file")"
      : >"$file"
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --set) echo "$2 = $3" >>"$file"; shift 3 ;;
          *) shift 2 ;;
        esac
      done
    '';
  };
in
pkgs.runCommand "flox-config-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      coreutils
      gnugrep
      yq-go
    ];
  }
  ''
    ${suite floxConfig}
    if (${suite replacing}) >/dev/null 2>&1; then echo "FAIL the replacing mutant passed the suite"; exit 1; fi
    echo "ok   the replacing mutant is refused"
    touch $out
  ''
