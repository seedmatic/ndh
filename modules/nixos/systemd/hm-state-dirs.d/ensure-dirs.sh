source @nixBashTrampoline@

main() {
  set -euo pipefail
  for entry in @dirsWithModes@; do
    d="${entry%%|*}"
    mode="${entry##*|}"

    install -d -m "$mode" -o @userName@ -g @group@ "$d"
    chown @userName@:@group@ "$d" || true
    chmod "$mode" "$d" || true
  done

  if [ -d "@secretsRootDir@" ]; then
    chown -R @userName@:@group@ "@secretsRootDir@" || true
  fi
}

ndh::logger:command:run "@loggerTag@" main "$@"
