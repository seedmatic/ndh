# NDH Code Conventions

This document defines coding standards and patterns for the nix-darwin-home (NDH) repository.

## Table of Contents

- [LaunchAgent Naming](#launchagent-naming)
- [Module Structure](#module-structure)
- [Script Externalization](#script-externalization)
- [Nix Options Priority](#nix-options-priority)
- [Documentation Standards](#documentation-standards)

## LaunchAgent Naming

**Rule**: All LaunchAgents added by NDH must use the `io.nxmatic.nix-darwin-home` prefix.

### Pattern

```nix
launchd.user.agents.my-agent = {
  serviceConfig = {
    Label = "io.nxmatic.nix-darwin-home-my-agent";  # Always set explicit Label
    ProgramArguments = [ "${myScript}" ];
    # ... rest of config
  };
};
```

### Naming Variants

| Context             | Pattern                              | Example                                            |
| ------------------- | ------------------------------------ | -------------------------------------------------- |
| Darwin system agent | `io.nxmatic.nix-darwin-home-<name>`  | `io.nxmatic.nix-darwin-home-tailscale-vnc-forward` |
| Home Manager agent  | `io.nxmatic.nix-darwin-home.<name>`  | `io.nxmatic.nix-darwin-home.ssh-add-keys`          |

### Why?

- **Consistency**: Makes all NDH agents easily identifiable in `launchctl list`
- **Namespace**: Avoids conflicts with system agents or other tools
- **Debugging**: Clear ownership when troubleshooting agent issues

### ✅ Correct Examples

```nix
# Darwin agent
launchd.user.agents.bringup-observe-vector = {
  serviceConfig = {
    Label = "io.nxmatic.nix-darwin-home-bringup-observe-vector";
  };
};

# Home Manager agent
launchd.user.agents.ssh-add-keys = {
  serviceConfig = {
    Label = "io.nxmatic.nix-darwin-home.home.ssh-add-keys";
  };
};
```

### ❌ Incorrect Examples

```nix
# Missing explicit Label - uses nix-darwin default "org.nixos.*"
launchd.user.agents.my-agent = {
  serviceConfig = {
    ProgramArguments = [ "${myScript}" ];
  };
};

# Wrong prefix
launchd.user.agents.my-agent = {
  serviceConfig = {
    Label = "org.nixos.my-agent";  # ❌ Wrong prefix
  };
};
```

## Module Structure

### Module Organization

```
modules/
├── .common.d/          # Shared Darwin + NixOS
│   ├── default.nix     # Defines ndh.store API, logger, trampoline
│   └── *.nix          # Cross-platform utilities
├── darwin/             # macOS-specific
│   ├── default.nix     # Module index
│   └── *.nix          # Darwin-only modules
├── nixos/              # Linux-specific
│   ├── default.nix     # Module index
│   └── *.nix          # NixOS-only modules
└── home-manager/       # User environment (cross-platform)
    ├── default.nix     # HM module index
    └── *.nix          # User-level configuration
```

### Module Template

```nix
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.myService;
in
{
  options.services.myService = {
    enable = lib.mkEnableOption "My Service";
    
    serverUrl = lib.mkOption {
      type = lib.types.str;
      description = "Server URL";
      example = "https://example.com";
    };
  };

  config = lib.mkIf cfg.enable {
    # Implementation
  };
}
```

### Cross-Platform Modules

**CRITICAL**: `modules/.common.d/default.nix` is imported by **both** Darwin and NixOS. Changes here affect all systems.

Always guard platform-specific code:

```nix
# ✅ Correct
config = {
  environment.systemPackages = lib.optionals pkgs.stdenv.isDarwin [
    pkgs.darwin-only-tool
  ] ++ lib.optionals pkgs.stdenv.isLinux [
    pkgs.linux-only-tool
  ];
};

# ❌ Wrong - assumes Darwin
config = {
  launchd.user.agents.my-agent = {  # Will fail on NixOS!
    # ...
  };
};
```

## Script Externalization

**Rule**: All externalized shell scripts must use `ndh.store.*` helpers, **not** bare `pkgs.writeShellScript`.

### Why?

The `ndh.store` API provides:
- Consistent bash trampoline with proper PATH setup
- Standardized logging integration
- Variable templating via `replaceVars`
- Deterministic store paths

### ✅ Correct Pattern

```nix
let
  myScript = pkgs.replaceVars "${self}/scripts/my-script.sh" {
    nixBashTrampoline = nixBashTrampoline;
    loggerTag = "my-service";
    someVar = "value";
  };
in
{
  # Use myScript in configuration
}
```

### ❌ Incorrect Pattern

```nix
# ❌ Don't use bare writeShellScript
let
  myScript = pkgs.writeShellScript "my-script" ''
    #!/usr/bin/env bash
    # ...
  '';
in
```

### Script Structure

External scripts should use the trampoline pattern:

```bash
#!/usr/bin/env -S bash -euo pipefail
# @nixBashTrampoline@

# Script has proper PATH, logging helpers, and NDH context
logger -t "@loggerTag@" "Starting operation"
```

See `.github/skills/nix-darwin-home/SKILL.md` for full details.

## Nix Options Priority

### Priority Levels

| Function | Priority | Use Case |
|----------|----------|----------|
| `lib.mkDefault` | 1000 (low) | Default values, allow flake-level overrides |
| `lib.mkOverride 900` | 900 | Between default and normal |
| (no wrapper) | 100 (normal) | Standard module config |
| `lib.mkForce` | 50 (high) | Override all other priorities |

### When to Use Each

#### `lib.mkDefault` - Preferred Default

Use for **module defaults** that should be overridable:

```nix
# ✅ Allows flake-level overrides
limaHost.hostName = lib.mkDefault (profile.host.hostAlias or profile.host.hostName);
```

#### `lib.mkForce` - Use Sparingly

Use only when you **must** override other modules:

```nix
# ✅ Justified: enforce system hostname
networking.hostName = lib.mkForce profile.host.hostName;

# ❌ Wrong: prevents composition
services.myService.enable = lib.mkForce true;  # Breaks override attempts
```

**IMPORTANT**: Overusing `mkForce` breaks module composition. Always prefer `mkDefault` or `mkOverride` unless you have a specific reason.

## Documentation Standards

### File Formats

| Format | Use For | Location |
|--------|---------|----------|
| AsciiDoc (`.adoc`) | Architecture docs, guides, session notes | `docs/`, `.github/copilot.d/` |
| Markdown (`.md`) | Short references, skill definitions | `.github/`, `README.md` |
| Inline comments | Implementation notes, `@codebase` tags | Source files |

### @codebase Comments

Use `@codebase` tags to mark **architectural decisions** and **migration paths**:

```nix
# NOTE (@codebase): Rollback instructions:
#   - Remove "ca-derivations" from experimental-features.
#   - Set auto-optimise-store = true to restore inline dedup.
```

**IMPORTANT**: Preserve `@codebase` comments when editing. They document critical context.

### Module Documentation

Each non-trivial module should include:

1. **Purpose comment** at the top
2. **Options documentation** via `description` field
3. **Example configuration** in description
4. **Dependencies** if non-obvious

```nix
# modules/darwin/my-service.nix
#
# Manages the MyService daemon on macOS hosts.
# Requires Tailscale for authentication.

{
  options.services.myService = {
    enable = lib.mkEnableOption "MyService daemon";
    
    serverUrl = lib.mkOption {
      type = lib.types.str;
      description = ''
        Server URL for MyService.
        
        Example: `https://my-service.example.com`
      '';
    };
  };
}
```

## Session Notes

See `.github/copilot.d/session-handover-*.adoc` for examples of:
- Capturing architectural context
- Documenting work in progress
- Creating handover notes for future sessions

## References

- Full skill documentation: `.github/skills/nix-darwin-home/SKILL.md`
- Project overview: `.github/copilot-instructions.adoc`
- Collaboration guide: `docs/collaboration-guide.adoc` (if exists)
