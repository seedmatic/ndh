# The vz-recover key's authorized_keys options and the program they force, as installed in a vz-host account's
# nix profile: one source for the package's real-sshd check and for the line ndh-keyring prints.
{
  options = command: ''restrict,command="${command}"'';
  installed = home: "${home}/.nix-profile/bin/ndh-vz-recover";
  # What `probe` prints, and nothing else: a caller goes on only when it reads exactly this.
  probeMarker = version: "ndh-vz-recover ok ${version}";
}
