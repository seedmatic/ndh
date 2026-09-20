# The two sshd authorization helpers, built once for every consumer: the NixOS
# and Darwin openssh modules, and the baremetal enrollment app that installs the
# same policy onto a host no generation manages.
#
# A plain function rather than a module option: openssh-policy.nix is also
# imported by the bringup config, and giving that module a new required argument
# would make the bringup depend on scope it does not carry.  Callers pass what
# they already hold, so the module graph is untouched.
#
# `sshCommonDir` is a parameter rather than `./.` here on purpose — every caller
# already resolves modules/.common.d through worktreePath, and reading the two
# scripts through that same path is what keeps the produced store paths
# identical to what each platform built before this extraction.
{
  pkgs,
  ndh,
  sshCommonDir,
  nixBashTrampoline,
  principalsInputPath,
  authorizedKeysDir,
}:
ndh.store.installBinScriptBundle "openssh-authz-tools" {
  openssh-principals-command = pkgs.replaceVars "${sshCommonDir}/authorized-principals-command.sh" {
    inherit nixBashTrampoline principalsInputPath;
  };
  openssh-group-authorized-keys = pkgs.replaceVars "${sshCommonDir}/ssh-group-authorized-keys.sh" {
    inherit nixBashTrampoline authorizedKeysDir;
  };
}
