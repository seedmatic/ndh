# The v4 half of the seat's corp-egress anchor, rendered from the catalog: what the seat may still send to the
# corporate bare-metal, and the block of everything else. The v6 half is not here: the home /64 and the host's
# link-local addresses come from sops at activation (anchor.sh), never from a derivation.
#
# Every allow is listed in `allows`, and the check compares them with the corpus: a widened allow turns it red.
{
  lanAddress,
  linkAddress,
  user,
}:
let
  allows = [
    # The operator's ssh and vz-recover, on the LAN address only and from the operator's own sockets.
    "pass out quick inet proto tcp to ${lanAddress} port 22 user ${user} keep state"
  ];
  blocks = [
    "block out quick log inet to ${lanAddress}"
    "block out quick log inet to ${linkAddress}"
  ];
in
{
  inherit allows;
  text = builtins.concatStringsSep "\n" (allows ++ blocks);
  # What pf loads at boot before any activation has read the secret: the two v4 blocks, no allow and no v6. It fails
  # closed on v4 and is replaced whole by the full anchor at the next activation.
  floor = builtins.concatStringsSep "\n" blocks + "\n";
}
