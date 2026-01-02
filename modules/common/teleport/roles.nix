{
  config,
  lib,
  pkgs,
  ...
}:

# Teleport RBAC roles that map to your existing SSH principals
# These can be imported into Teleport using: tctl create -f roles.yaml

let
  # Generate YAML role definitions
  rolesYaml = pkgs.writeText "teleport-roles.yaml" ''
    ---
    kind: role
    version: v7
    metadata:
      name: admin
    spec:
      allow:
        logins: ['{{internal.logins}}', 'root']
        node_labels:
          '*': '*'
        kubernetes_groups: ['system:masters']
        rules:
          - resources: ['*']
            verbs: ['*']
      options:
        max_session_ttl: 24h
        port_forwarding: true
        forward_agent: true
        ssh_file_copy: true

    ---
    kind: role
    version: v7
    metadata:
      name: committed
    spec:
      allow:
        logins: ['{{internal.logins}}', 'nxmatic', 'root']
        node_labels:
          'env': ['development', 'production']
        rules:
          - resources: ['*']
            verbs: ['list', 'read']
      options:
        max_session_ttl: 8h
        port_forwarding: true
        forward_agent: true

    ---
    kind: role
    version: v7
    metadata:
      name: work
    spec:
      allow:
        logins: ['{{internal.logins}}', 'nxmatic', 'stephane.lacoin']
        node_labels:
          'env': ['development', 'staging', 'production']
        kubernetes_groups: ['system:masters']
        rules:
          - resources: ['*']
            verbs: ['*']
      options:
        max_session_ttl: 12h
        port_forwarding: true
        forward_agent: true
        ssh_file_copy: true

    ---
    kind: role
    version: v7
    metadata:
      name: linux-builder
    spec:
      allow:
        logins: ['builder', 'nxmatic']
        node_labels:
          'role': ['node']
          'hostname': ['linux-builder']
      options:
        max_session_ttl: 24h
        port_forwarding: true
  '';

  # Script to import roles into Teleport
  importRolesScript = pkgs.writeShellScriptBin "teleport-import-roles" ''
    set -euxo pipefail

    if ! command -v tctl &> /dev/null; then
      echo "Error: tctl not found. Make sure Teleport is installed." >&2
      exit 1
    fi

    : "Importing Teleport roles"
    ${pkgs.teleport}/bin/tctl create -f ${rolesYaml}

    echo ""
    echo "Roles imported successfully!"
    echo ""
    echo "To assign roles to a user:"
    echo "  tctl users update <username> --set-roles=committed,work"
  '';
in
{
  environment.systemPackages = [ importRolesScript ];

  # Export the roles file for reference
  # Darwin and NixOS handle etc files differently
  environment.etc."teleport/roles.yaml" = lib.mkMerge [
    { source = rolesYaml; }
    (lib.mkIf pkgs.stdenv.isLinux { mode = "0644"; })
  ];
}
