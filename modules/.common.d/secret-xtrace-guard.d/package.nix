# secret-xtrace-guard: no secret VALUE reaches a trace or an argv in the scripts ndh runs (check.py). Built over
# the repo's own .sh files at the revision, no IFD: shfmt parses each, the checker reads the ASTs. REPORT mode in
# batch G: it fails only on its strict classes; batch 1 makes the report classes it gates strict with the flip.
{ pkgs, src }:
let
  lib = pkgs.lib;
  # Every .sh but the logger and the trampoline, which define the windows; tests, the vendored flox envs and the
  # git hooks are left out below, by path.
  scripts = lib.fileset.toSource {
    root = src;
    fileset = lib.fileset.fileFilter (
      f: f.hasExt "sh" && f.name != "logger.sh" && f.name != "nix-bash-trampoline.sh"
    ) src;
  };
  # What shfmt cannot parse, with the reason a reviewer accepted: never a script that handles a secret.
  # shfmt reads an unquoted `#` right after a quoted word as a comment; bash reads it as a literal.
  unparseable = {
    "modules/nixos/systemd/nixos-rebuild-guest.sh" =
      "shfmt: `\"$FLAKE\"#@systemAttr@`; runs nix builds, no secret";
    "modules/nixos/systemd/system-manual-boot.sh" =
      "shfmt: `\"$FLAKE\"#@systemAttr@`; sets a boot generation, no secret";
  };
  # A tracked value handed to a function the check cannot follow, followed by a reviewer: the function, and the
  # channel the value reaches a command through. All three scripts carry the whole-script guard (no trace).
  reviewed = {
    "modules/.common.d/identity-push.d/ndh-identity-push.sh" = {
      pubOf = "builtin printf into a pipe (base64, tr): no argv";
      log = "receives the derived PUBLIC (pubOf's output), tracked by over-detection";
    };
    "modules/.common.d/ssh-keys.d/ssh-enrich-keys-yaml.sh" = {
      "key::set_field" = "slot::set: VALUE=… yq strenv(VALUE), a prefix assignment: environment, no argv";
    };
    "modules/home-manager/git.d/sops.sh" = {
      "git::sops" =
        "decrypt reads stdin (a here-string); show is builtin printf to git's textconv: no argv";
    };
  };
in
pkgs.runCommand "secret-xtrace-guard"
  {
    nativeBuildInputs = [
      pkgs.shfmt
      pkgs.python3
      pkgs.findutils
    ];
    passAsFile = [
      "unparseable"
      "reviewed"
    ];
    unparseable = builtins.toJSON unparseable;
    reviewed = builtins.toJSON (lib.mapAttrs (_: lib.attrNames) reviewed);
  }
  ''
    cd ${scripts}
    work=$TMPDIR/asts
    mkdir -p "$work"
    i=0
    {
      printf '['
      sep=""
      while IFS= read -r -d "" f; do
        f=''${f#./}
        case "/$f" in */tests/* | */test/* | /.flox* | /.githooks/*) continue ;; esac
        i=$((i + 1))
        tramp=false
        grep -qE 'source "?@nixBashTrampoline@"?' "$f" && tramp=true
        if ! shfmt --to-json <"$f" >"$work/$i.json" 2>"$work/$i.err"; then
          python3 -c 'import json,sys; json.dump({"ParseError": open(sys.argv[1]).read().strip()}, open(sys.argv[2], "w"))' \
            "$work/$i.err" "$work/$i.json"
        fi
        exempt=$(python3 -c 'import json,sys; print("true" if sys.argv[2] in json.load(open(sys.argv[1])) else "false")' \
          "$unparseablePath" "$f")
        hops=$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get(sys.argv[2], [])))' \
          "$reviewedPath" "$f")
        printf '%s{"path": "%s", "ast": "%s", "trampoline": %s, "exempt": %s, "reviewed": %s}' \
          "$sep" "$f" "$work/$i.json" "$tramp" "$exempt" "$hops"
        sep=","
      done < <(find . -name '*.sh' -print0 | sort -z)
      printf ']\n'
    } >"$work/manifest.json"
    echo "secret-xtrace-guard: $i scripts"
    # The checker's status IS the check's: never behind a pipe.
    rc=0
    python3 -I ${./check.py} "$work/manifest.json" >$TMPDIR/report || rc=$?
    cat $TMPDIR/report
    [ "$rc" = 0 ] || exit "$rc"
    mkdir -p $out
    cp $TMPDIR/report $out/report
  ''
