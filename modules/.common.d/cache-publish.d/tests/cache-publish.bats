#!/usr/bin/env bats
#
# cache-publish: from a revision only, the publishable part of the allow-listed closure — upstream
# paths left alone, added paths and secret shapes private, and private spreading to whatever reaches
# it — pushed with --apply alone, then checked against the public cache. nix, curl and cachix are
# stubbed over a fake store; yq, grep, awk and find are real.

rev=0123456789abcdef0123456789abcdef01234567

setup() {
  t="$BATS_TEST_TMPDIR"
  s="$t/store"
  mkdir -p "$t/bin" "$s"
  : >"$t/public.hashes"
  printf 'up1\n' >"$t/upstream.hashes"

  mk() { # <hash-name> <file content>
    mkdir -p "$s/$1"
    printf '%s\n' "$2" >"$s/$1/file"
  }
  mk up1-glibc "upstream"
  mk src1-source "a flake tree"
  mk pkga-tool "a clean build"
  mk pkgb-wrapper "a build that refers to its source"
  mk sys1-system "the aggregate"
  mk leak1-cfg "token AGE-SECRET-KEY-1$(printf 'Q%.0s' {1..58})"
  mk armr-keys "$(printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\n%s' "$(printf 'b%.0s' {1..64})")"
  mk hdr1-ssh "$(printf -- 'grep for -----BEGIN OPENSSH PRIVATE KEY-----\nto tell a key file')"
  mk sopb-secret "$(printf '# sops:encrypted\nprivate: hunter2')"
  mk sopk-secret "$(printf '# sops:encrypted\nprivate: ENC[AES256_GCM,data:x]')"
  mk awsk-cfg "key=AKIA$(printf 'Z%.0s' {1..16})"
  mk awss-cred "aws_secret_access_key = $(printf 'w%.0s' {1..40})"
  mk awsd-doc "the AKIA prefix names an access key; set aws_secret_access_key = <yours>"

  # sys reaches everything; the allow-list has two attributes.
  printf '%s\n' "$s/sys1-system" >"$t/build.a"
  printf '%s\n%s\n' "$s/leak1-cfg" "$s/armr-keys" >"$t/build.b"
  p() { # <hash-name> <deriver or null> <references…>
    local name="$1" drv="$2" refs="" r
    shift 2
    for r in "$name" "$@"; do refs="$refs\"$s/$r\","; done
    printf '"%s":{"deriver":%s,"references":[%s]},' "$s/$name" "$drv" "${refs%,}"
  }
  {
    printf '{'
    p up1-glibc '"/d/up1.drv"'
    p src1-source null
    p pkga-tool '"/d/a.drv"' up1-glibc
    p pkgb-wrapper '"/d/b.drv"' src1-source pkga-tool
    p leak1-cfg '"/d/l.drv"'
    p armr-keys '"/d/k.drv"'
    p hdr1-ssh '"/d/h.drv"'
    p sopb-secret '"/d/sb.drv"'
    p sopk-secret '"/d/sk.drv"'
    p awsk-cfg '"/d/ak.drv"'
    p awss-cred '"/d/as.drv"'
    p awsd-doc '"/d/ad.drv"'
    p sys1-system '"/d/s.drv"' pkga-tool pkgb-wrapper leak1-cfg armr-keys hdr1-ssh sopb-secret sopk-secret \
      awsk-cfg awss-cred awsd-doc | sed 's/,$//'
    printf '}'
  } >"$t/closure.json"

  cat >"$t/bin/nix" <<EOF
#!$BASH
printf '%s\n' "\$*" >>"$t/nix.calls"
case "\$1" in
  build) attr="\${@: -1}"; cat "$t/build.\${attr##*#}" ;;
  path-info) cat "$t/closure.json" ;;
esac
EOF
  cat >"$t/bin/curl" <<EOF
#!$BASH
url="\${@: -1}"; hash="\${url##*/}"; hash="\${hash%.narinfo}"
case "\$url" in
  https://up.test/*) list="$t/upstream.hashes" ;;
  https://pub.test/*) list="$t/public.hashes" ;;
esac
grep -qx "\$hash" "\$list" && printf 200 || printf 404
EOF
  cat >"$t/bin/cachix" <<EOF
#!$BASH
printf '%s\n' "\$*" >>"$t/cachix.argv"
case "\$1" in
  authtoken) cat >"$t/cachix.token" ;;
  push) while read -r path; do basename "\$path" | cut -d- -f1; done >>"$t/public.hashes"
        [ -z "\${DROP:-}" ] || sed -i.bak "/^\$DROP\$/d" "$t/public.hashes" ;;
esac
EOF
  chmod +x "$t/bin/"*
  printf 'the-push-token\n' >"$t/token"

  script="${BATS_TEST_DIRNAME}/../cache-publish.sh"
  export OUTPUTS=$'a\nb' CACHE=nxmatic PUBLIC_URL=https://pub.test UPSTREAMS=https://up.test \
    TOKEN_FILE="$t/token" JOBS=4
}

publish() { PATH="$t/bin:$PATH" run bash -euo pipefail "$script" "$@"; }
listed() { printf '%s\n' "$output" | grep "^$1 " | sed "s|$s/||" | cut -d' ' -f2- | sort | tr '\n' ' '; }

@test "the publishable set is the clean builds; added paths, secret shapes and what reaches them stay private" {
  publish "git+file:///repo?ref=develop&rev=$rev"
  [ "$status" -eq 0 ]
  [ "$(listed publish)" = "awsd-doc hdr1-ssh pkga-tool sopk-secret " ]
  [ "$(listed private)" = "added src1-source guard armr-keys guard awsk-cfg guard awss-cred guard leak1-cfg guard sopb-secret reaches pkgb-wrapper reaches sys1-system " ]
}

@test "a dry run pushes nothing and reads no token" {
  publish "github:seedmatic/ndh/$rev"
  [ "$status" -eq 0 ]
  [ ! -e "$t/cachix.argv" ]
  [[ $output == *"dry run: nothing pushed"* ]]
}

@test "anything but a revision is refused before any build" {
  for ref in "git+file:///repo?ref=develop" ".#a" "path:/repo?rev=$rev" "github:seedmatic/ndh" "/repo?rev=$rev"; do
    publish "$ref"
    [ "$status" -eq 1 ]
    [[ $output == *"revision"* ]]
  done
  [ ! -e "$t/nix.calls" ]
}

@test "--apply pushes exactly the publishable set, with the token through cachix's stdin" {
  publish --apply "git+file:///repo?rev=$rev"
  [ "$status" -eq 0 ]
  [ "$(sort "$t/public.hashes" | tr '\n' ' ')" = "awsd hdr1 pkga sopk " ]
  [ "$(cat "$t/cachix.token")" = the-push-token ]
  [[ $output != *the-push-token* ]]
  run grep -q the-push-token "$t/cachix.argv"
  [ "$status" -eq 1 ]
}

@test "--apply fails loudly when a private path is already public" {
  printf 'src1\n' >"$t/public.hashes"
  publish --apply "git+file:///repo?rev=$rev"
  [ "$status" -eq 1 ]
  [[ $output == *"PRIVATE path served by the public cache"*"src1-source"* ]]
}

@test "--apply fails when a published path is not served afterwards" {
  DROP=pkga publish --apply "git+file:///repo?rev=$rev"
  [ "$status" -eq 1 ]
  [[ $output == *"missing after the push"*"pkga-tool"* ]]
}
