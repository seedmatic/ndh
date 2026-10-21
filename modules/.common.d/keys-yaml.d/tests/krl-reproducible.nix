# The fleet's KRL is a function of keys.json alone: two builds a second apart give the same bytes, its
# generated_date is zero, and it still refuses every revoked public. The mutant is a build that keeps
# ssh-keygen's own stamp: it must differ from the next one, or this check proves nothing.
{
  pkgs,
  keysJson,
}:
pkgs.runCommand "krl-reproducible"
  {
    nativeBuildInputs = with pkgs; [
      bash
      coreutils
      openssh
      yq-go
    ];
  }
  ''
    build() { bash ${../krl.sh} ${keysJson} "$1"; }
    build one.krl
    sleep 2
    build two.krl
    cmp one.krl two.krl || { echo "FAIL two builds of the same keys.json differ"; exit 1; }
    [ "$(od -An -tx1 -j20 -N8 one.krl | tr -d ' \n')" = 0000000000000000 ] ||
      { echo "FAIL the list's generated_date is not zero"; exit 1; }
    ssh-keygen -Q -l -f one.krl >/dev/null || { echo "FAIL ssh-keygen cannot read the zeroed list"; exit 1; }
    yq -r '(.revoked // {}) | to_entries[] | .value.type + " " + .value.public' ${keysJson} | while read -r line; do
      printf '%s\n' "$line" >k.pub
      if ssh-keygen -Q -f one.krl k.pub >/dev/null; then echo "FAIL a revoked public is not refused by the zeroed list"; exit 1; fi
    done
    echo "ok   two builds identical, date zeroed, every revoked public still refused"

    sed 's/^reproducible$/:/; s/^\treproducible$/\t:/' ${../krl.sh} >stamped.sh
    bash stamped.sh ${keysJson} m1.krl
    sleep 2
    bash stamped.sh ${keysJson} m2.krl
    if cmp -s m1.krl m2.krl; then echo "FAIL mutant: ssh-keygen's stamp gave identical builds"; exit 1; fi
    echo "ok   mutant refused: without the zeroing, two builds differ"
    touch $out
  ''
