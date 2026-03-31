# SSH Keys Management Architecture

**Version:** 1.0  
**Last Updated:** 2026-03-31  
**Scope:** nix-darwin-home SSH deployment pipeline  
**Status:** Production

> This document describes the complete SSH key management system including key extraction, certificate regeneration, and deployment to the runtime environment.

---

## Executive Summary

The SSH key management system automates deployment of cryptographic keys and certificates from a SOPS-encrypted source (`keys.yaml`) to a runtime directory (`~/.local/state/ssh-keys.d/`) at activation time. The pipeline ensures:

- **Fresh certificates** generated on each activation (new serial numbers)
- **Automatic CA signing** of keys with embedded authorities
- **Minimal manual intervention** (integrated into `home-manager switch`)
- **Ephemeral certificates** (not stored in git, always regenerated)
- **Runtime compatibility** with SSH agent auto-loading

---

## C1: System Context

```
┌─────────────────────────────────────────────────────────────┐
│                   User: nxmatic@nixos                       │
│                  (home-manager activation)                  │
└────────────────────┬────────────────────────────────────────┘
                     │
                     ├─ trigger: home-manager switch
                     │
        ┌────────────▼──────────────────────┐
        │  SSH Keys Management System       │
        │  (home-manager activation module) │
        │                                   │
        │  - Extract keys from SOPS secret  │
        │  - Regenerate certificates       │
        │  - Deploy to runtime directory   │
        └────────────────────┬──────────────┘
                     │
             ┌───────┼───────┐
             │       │       │
             ▼       ▼       ▼
        ┌────────┐ ┌──────┐ ┌────────────────────┐
        │ SSH    │ │ launchd│ SSH Agent           │
        │ Config │ │KeyChain│ (auto-loads *.pub) │
        └────────┘ └──────┘ └────────────────────┘
```

---

## C2: Container Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│                        Nix Flake (home profile)                          │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────┐    │
│  │            home-manager activation system                     │    │
│  │                                                               │    │
│  │  ┌──────────────────┐  ┌───────────────────────────────────┐ │    │
│  │  │ SOPS Decryption  │  │ SSH Keys Deployment Module        │ │    │
│  │  │ /run/secrets/    │  │ (modules/home-manager/ssh-*.nix)  │ │    │
│  │  │ nxmatic-ssh-..   │  │ + script framework                │ │    │
│  │  │ (profile YAML)   │  │                                   │ │    │
│  │  └────────┬─────────┘  └───┬─────────────────────────────┬─┘ │    │
│  │           │                │                             │   │    │
│  │           │  plaintext     │  activation                 │   │    │
│  │           │  profile YAML  │  scripts                    │   │    │
│  │           └───────────┬────┴──────────────────┬──────────┘   │    │
│  │                       │                       │              │    │
│  │           ┌───────────▼───────────────────────▼───────────┐  │    │
│  │           │   SSH Deployment Pipeline                    │  │    │
│  │           │                                              │  │    │
│  │           │  1. extract-keys.sh (key → pub/priv)        │  │    │
│  │           │  2. regenerate-certs.sh (sign with CAs)    │  │    │
│  │           │  3. deploy-ssh-keys.sh (rsync to runtime)   │  │    │
│  │           │  4. ensure-authorized-keys.sh (create perms)│  │    │
│  │           │                                              │  │    │
│  │           └────────────┬─────────────────────────────────┘  │    │
│  │                        │                                    │    │
│  │                ┌───────▼───────────────────────┐           │    │
│  │                │ ~/.local/state/ssh-keys.d/   │           │    │
│  │                │ (runtime keys + certs)       │           │    │
│  │                └───────┬───────────────────────┘           │    │
│  │                        │                                    │    │
│  └────────────────────────┼────────────────────────────────────┘    │
│                           │                                          │
└─────────────────┬──────────┼──────────────────────────────────────────┘
                  │          │
                  │    ┌─────▼──────────────┐
                  │    │  ~/.ssh/config     │
                  │    │  known_hosts       │
                  │    │  authorized_keys   │
                  │    └────────────────────┘
                  │
                  └─► SSH Agent / LaunchAgent
```

---

## C3: Component Architecture (Extract → Regenerate → Deploy)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         SSH Keys Deployment Pipeline                        │
│                                                                             │
│  STAGE 1: KEY EXTRACTION                                                    │
│  ┌──────────────────────────────────────────────────────────────────┐      │
│  │ ssh-extract-keys.sh                                             │      │
│  │ ────────────────────────────────────────────────────────────── │      │
│  │ Input:  Profile YAML (one profile from keys.yaml)              │      │
│  │ Process:                                                        │      │
│  │   1. Parse YAML with yq (to_entries, select, splitdoc)        │      │
│  │   2. Extract key fields: private, public, authorities          │      │
│  │   3. Output temp files: <key>, <key>.pub, <key>-<ca>-ca.pub   │      │
│  │ Output: Directory of raw key files                             │      │
│  └──────────────────────────────────────────────────────────────────┘      │
│                              ▼                                              │
│                      [tmp_keys_dir filled]                                  │
│                              ▼                                              │
│  STAGE 2: CERTIFICATE REGENERATION                                         │
│  ┌──────────────────────────────────────────────────────────────────┐      │
│  │ ssh-regenerate-certs.sh                                         │      │
│  │ ────────────────────────────────────────────────────────────── │      │
│  │ Input:  Profile YAML + tmp_keys_dir (from Stage 1)            │      │
│  │ Process:                                                        │      │
│  │   For each key with embedded authorities:                      │      │
│  │   1. Extract key public, type, comment                         │      │
│  │   2. For each authority CA:                                    │      │
│  │      - Extract CA private key                                  │      │
│  │      - Write to temp files (secure, 0400)                      │      │
│  │      - ssh-keygen -s <ca-priv> → sign key                     │      │
│  │      - Generate <key>-<authority>-user-cert.pub                │      │
│  │   3. Create stable symlink: <key>-cert.pub → cert file        │      │
│  │ Output: Directory with certs added (+ symlinks)                │      │
│  └──────────────────────────────────────────────────────────────────┘      │
│                              ▼                                              │
│              [tmp_keys_dir now has certs + symlinks]                        │
│                              ▼                                              │
│  STAGE 3: DEPLOYMENT                                                       │
│  ┌──────────────────────────────────────────────────────────────────┐      │
│  │ deploy-ssh-keys.sh                                              │      │
│  │ ────────────────────────────────────────────────────────────── │      │
│  │ Input:  Profile YAML + tmp_keys_dir (from Stage 2)            │      │
│  │ Process:                                                        │      │
│  │   1. Generate agent-keys manifest (keys to load at startup)    │      │
│  │      - Filter: only keys with private material AND             │      │
│  │        usage ∈ {agent-signing, user-signing, ssh-user, ...}  │      │
│  │   2. rsync tmp_keys_dir → ~/.local/state/ssh-keys.d/ with:    │      │
│  │      --delete (clean stale files)                             │      │
│  │      --chmod=u+w,go-r (keys readable only by user)            │      │
│  │      --chown=$USER:$GROUP (correct ownership)                 │      │
│  │   3. Defensive cleanup: remove certs that don't match keys    │      │
│  │      (compare fingerprints with ssh-keygen -L)                 │      │
│  │ Output: Keys + certs + symlinks in ~/.local/state/ssh-keys.d/ │      │
│  └──────────────────────────────────────────────────────────────────┘      │
│                              ▼                                              │
│               [Final runtime directory populated]                           │
│                                                                             │
│  STAGE 4: AUTHORIZATION (optional)                                         │
│  ┌──────────────────────────────────────────────────────────────────┐      │
│  │ ensure-authorized-keys.sh                                       │      │
│  │ ────────────────────────────────────────────────────────────── │      │
│  │ Input:  SSH keys from Stage 3                                  │      │
│  │ Process:                                                        │      │
│  │   1. Ensure ~/.ssh/authorized_keys exists (mutable, no symlink)│      │
│  │   2. Set strict permissions (0600)                             │      │
│  │   3. Can append additional CA principals if needed             │      │
│  │ Output: Mutable authorized_keys file ready for use             │      │
│  └──────────────────────────────────────────────────────────────────┘      │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Data Flow Diagram

```
Keys YAML (encrypted)
      │
      ├─ [SOPS decryption at activation time]
      │
      ▼
Plaintext Profile YAML
{
  github-signing: { type, public, private, ... }
  rke2-cluster: { type, public, private, authorities: { mammoth-skate: { private, public, ... } } }
  mammoth-skate: { type, usage, private, public, ... }
  host: { type, usage, authorities: { mammoth-skate: { private, ... } } }
  linux-builder: { type, public, private, authorities: { mammoth-skate: { ... } } }
}
      │
      ├─ [STAGE 1: ssh-extract-keys.sh]
      │  ├─ Extracts ~/.local/state/ssh-keys.d/github-signing (private)
      │  ├─ Extracts ~/.local/state/ssh-keys.d/github-signing.pub (public)
      │  ├─ Extracts ~/.local/state/ssh-keys.d/rke2-cluster (private)
      │  ├─ Extracts ~/.local/state/ssh-keys.d/rke2-cluster.pub (public)
      │  ├─ Extracts ~/.local/state/ssh-keys.d/rke2-cluster-mammoth-skate-ca.pub (CA authority)
      │  └─ ... (same for other keys/authorities)
      │
      ▼
Raw keys directory (Stage 1 output)
      │
      ├─ [STAGE 2: ssh-regenerate-certs.sh]
      │  ├─ For rke2-cluster + mammoth-skate authority:
      │  │  └─ ssh-keygen -s mammoth-private -I rke2-cluster → rke2-cluster-mammoth-skate-user-cert.pub
      │  │
      │  ├─ For linux-builder + mammoth-skate authority:
      │  │  └─ ssh-keygen -s mammoth-private -I linux-builder → linux-builder-mammoth-skate-user-cert.pub
      │  │
      │  ├─ Create symlink: rke2-cluster-cert.pub → rke2-cluster-mammoth-skate-user-cert.pub
      │  └─ Create symlink: linux-builder-cert.pub → linux-builder-mammoth-skate-user-cert.pub
      │
      ▼
Keys directory with certificates (Stage 2 output)
      │
      ├─ [STAGE 3: deploy-ssh-keys.sh]
      │  ├─ Generate agent-keys manifest (list of keys to load)
      │  └─ rsync with --delete, --chmod, --chown
      │
      ▼
~/.local/state/ssh-keys.d/
├─ agent-keys (manifest)
├─ github-signing (private)
├─ github-signing.pub (public)
├─ rke2-cluster (private)
├─ rke2-cluster.pub (public)
├─ rke2-cluster-mammoth-skate-ca.pub (CA key)
├─ rke2-cluster-mammoth-skate-user-cert.pub (certificate)
├─ rke2-cluster-cert.pub → rke2-cluster-mammoth-skate-user-cert.pub (symlink)
├─ linux-builder (private)
├─ linux-builder.pub (public)
├─ linux-builder-mammoth-skate-ca.pub (CA key)
├─ linux-builder-mammoth-skate-user-cert.pub (certificate)
├─ linux-builder-cert.pub → linux-builder-mammoth-skate-user-cert.pub (symlink)
└─ ... (permissions: u+rw, go-r)
      │
      └─► SSH Agent loads agent-keys manifest + auto-loads -cert.pub sidecars
          ▼
          Certificate-based SSH auth ready!
```

---

## File Organization

### Source Files (in git repository)

```
modules/home-manager/
├── ssh-keys.nix                          # Main Nix module (wires everything up)
├── ssh-extract-keys.sh                   # Stage 1: Extract keys from profile YAML
├── ssh-regenerate-certs.sh               # Stage 2: Sign keys with CA authorities
├── ssh-keys.d/
│   ├── deploy-ssh-keys.sh               # Stage 3: Deploy to runtime + generate manifest
│   ├── ensure-authorized-keys.sh        # Stage 4: Ensure authorized_keys file exists
│   ├── scripts/
│   │   ├── ca-known-hosts-command.sh    # External helper for known_hosts with CA
│   │   └── authorized-principals-command.sh
│   └── config                            # SSH client config template
```

### Runtime Files (generated at activation)

```
~/.local/state/ssh-keys.d/               # XDG_STATE_HOME/ssh-keys.d
├── agent-keys                            # Manifest: keys to load in SSH agent
│
├── [Keys loaded at activation]
├── github-signing                        # Private key
├── github-signing.pub                    # Public key
├── rke2-cluster                          # Private key
├── rke2-cluster.pub                      # Public key
├── rke2-cluster-mammoth-skate-ca.pub    # CA authority public key
├── rke2-cluster-mammoth-skate-user-cert.pub  # ← Generated certificate (fresh each activation)
├── rke2-cluster-cert.pub                 # → Stable symlink to above cert
│
├── linux-builder                         # Private key
├── linux-builder.pub                     # Public key
├── linux-builder-mammoth-skate-ca.pub   # CA authority public key
├── linux-builder-mammoth-skate-user-cert.pub  # ← Generated certificate (fresh each activation)
├── linux-builder-cert.pub                # → Stable symlink to above cert
│
└── mammoth-skate (CA authority for bioskop)
    └── Public key available for known_hosts validation
```

### Secrets (encrypted at rest)

```
/run/secrets/nix-darwin-home/
├── nxmatic-ssh-keys.yaml                # ← SOPS-encrypted source
    │
    └─► Decrypted at activation to plaintext profile YAML
        (read-only, 0400 mode)
```

---

## Key Design Decisions

### 1. **Ephemeral Certificates**
- **Decision:** Certificates are regenerated at each activation, never stored in git
- **Rationale:** 
  - Ensures fresh serial numbers (security best practice)
  - Avoids tracking generated artifacts
  - Simplifies backup/restore (no stale cert confusion)
- **Trade-off:** Slightly slower activation (cert generation ~100ms per key)

### 2. **Embedded Authorities**
- **Decision:** Authority CA keys are embedded in the profile YAML (under `<key>.authorities.<ca-name>`)
- **Rationale:**
  - Single source of truth (keys + CAs in one YAML file)
  - No separate CA key management
  - Decryption happens once, CAs available inline
- **Trade-off:** Larger YAML payload (CA keys only ~4KB each, not significant)

### 3. **Activation-Time Generation**
- **Decision:** Certificates generated during `home-manager switch`, not at build time
- **Rationale:**
  - Timestamps/serial numbers reflect actual deployment time
  - Fresh CA signatures always current
  - No pre-built artifacts to manage or cache
- **Trade-off:** Can't verify certs without running full home-manager activation

### 4. **Stable Symlinks**
- **Decision:** `<key>-cert.pub` → `<key>-<authority>-user-cert.pub`
- **Rationale:**
  - SSH agent auto-loads sidecar `<key>-cert.pub` when loading `<key>` private key
  - One symlink per key instead of hard-coding authority-specific name
  - Easy to rotate CAs (just update symlink target)
- **Trade-off:** Adds symlink maintenance step in cert regeneration

---

## Sequence Diagram: Activation Flow

```
home-manager               ssh-keys.nix         Profile        Extraction     Regeneration      Deployment
  switch                   activation             YAML           Scripts         Scripts          Scripts
    │                         │                    │                │               │                │
    ├──trigger activation──────┼────────────────────────────────────────────────────────────────────┤
    │                         │                    │                │               │
    │                         ├─ Load profile───────────────────────────────────────────────────────┤ HOME
    │                         │  name from cfg      │                │               │
    │                         │                     │                │               │
    │                    [SOPS decrypt]           │                │               │
    │                         ├─ /run/secrets/──────────────────────────────────────────────────────┤
    │                         │  nxmatic-ssh-*.yaml                │               │
    │                         │        ▼                           │               │
    │                         │  Plaintext YAML                    │               │
    │                         │  (read-only, 0400)                 │               │
    │                         │                     │                │               │
    │                    [Extract keys] ◄──────────────────────────────────────────┤
    │                         ├─ deploySSHKeys activation script   │               │
    │                         │  (calls bash deploy-ssh-keys.sh)   │               │
    │                         │                                    │               │
    │                         │        ┌─ tmp_profile.yaml ┬──────▼────────────┐  │
    │                         │        │ (yq filter profile)│                   │  │
    │                         │        └────────────────────┴─ ssh-extract-keys.sh
    │                         │                                    │  output:      │
    │                         │                    ◄───────────────┼─ tmp_keys_dir │
    │                         │                                    │  (keys only)  │
    │                         │                                    │               │
    │                    [Regenerate certs] ◄────────────────────────────────────┤
    │                         │                                    │  ┌─ ssh-regenerate-certs.sh
    │                         │                    ◄───────────────┼─ (Signs keys with CAs)
    │                         │                                    │  (Generates *.cert.pub)
    │                         │                    ◄───────────────┼─ (Creates symlinks)
    │                         │                                    │  output:
    │                         │                                    │  tmp_keys_dir
    │                         │                                    │  (keys + certs)
    │                         │                                    │               │
    │                    [Deploy to runtime] ◄──────────────────────────────────────┤
    │                         │                                    │               │
    │                         │                                    │  ┌─ Generate agent-keys 
    │                         │                                    │  │ (manifest)
    │                         │                                    │  │
    │                         │                                    │  └─ rsync to
    │                         │                                    │     ~/.local/state/ssh-keys.d/
    │                         │                       ┌────────────┴─ deploy-ssh-keys.sh
    │                         ├─ ~/.local/state/ ◄────┘               (complete)
    │                         │  ssh-keys.d/
    │                         │  ├─ agent-keys       (manifest)
    │                         │  ├─ rke2-cluster     (private key)
    │                         │  ├─ rke2-cluster.pub
    │                         │  ├─ rke2-cluster-*-cert.pub  ◄── Fresh cert
    │                         │  ├─ rke2-cluster-cert.pub    ◄── Symlink
    │                         │  └─ ...
    │                         │
    │                    [Ensure authorized_keys]
    │                         ├─ ensureAuthorizedKeys
    │                         │  (ensure file exists,
    │                         │   set 0600 perms)
    │                         │
    ✓ Activation complete
         │
         └────► SSH Agent loads agent-keys
                Keychain auto-loads certs
                SSH auth ready ✓
```

---

## Common Operations & Troubleshooting

### Adding a New Key

1. **Edit `nxmatic-ssh-keys.yaml` (encrypted):**
   ```bash
   sops modules/home-manager/ssh.d/keys.yaml
   ```

2. **Add key entry under appropriate profile:**
   ```yaml
   profiles:
     committed:
       my-new-key:
         type: ssh-ed25519
         usage: [ssh-user]
         comment: my-new-key@bioskop
         public: AAAAC3NzaC1lZDI1NTE5...
         private: |
           -----BEGIN OPENSSH PRIVATE KEY-----
           ...
           -----END OPENSSH PRIVATE KEY-----
   ```

3. **Activate:**
   ```bash
   home-manager switch
   ```

4. **Verify:**
   ```bash
   ls -la ~/.local/state/ssh-keys.d/my-new-key*
   ssh-add -l | grep my-new-key
   ```

### Adding Authority Signing

1. **Add authority CA keys under target key:**
   ```yaml
   profiles:
     committed:
       rke2-cluster:
         type: ssh-ed25519
         public: ...
         private: ...
         authorities:
           mammoth-skate:  # Add this authority
             type: ssh-ed25519
             private: |  # CA private key
               -----BEGIN OPENSSH PRIVATE KEY-----
               ...
           -----END OPENSSH PRIVATE KEY-----
             public: ...   # CA public key
   ```

2. **Activate to regenerate certs:**
   ```bash
   home-manager switch
   ```

3. **Verify cert generated:**
   ```bash
   ls -la ~/.local/state/ssh-keys.d/rke2-cluster-mammoth-skate-user-cert.pub
   ssh-keygen -L -f ~/.local/state/ssh-keys.d/rke2-cluster-cert.pub
   ```

### Debugging Pipeline

1. **Check extraction (Stage 1):**
   ```bash
   # Manually test extract-keys.sh
   yq eval '.profiles.committed' /run/secrets/.../keys.yaml > /tmp/profile.yml
   bash modules/home-manager/ssh-extract-keys.sh /tmp/profile.yml /tmp/extracted/
   ls -la /tmp/extracted/
   ```

2. **Check cert regeneration (Stage 2):**
   ```bash
   # Test regenerate-certs.sh
   bash modules/home-manager/ssh-regenerate-certs.sh /tmp/profile.yml /tmp/extracted/
   ls -la /tmp/extracted/rke2-cluster*
   ssh-keygen -L -f /tmp/extracted/rke2-cluster-cert.pub  # Inspect cert
   ```

3. **Check deployment (Stage 3):**
   ```bash
   # Run activation manually
   bash modules/home-manager/ssh-keys.d/deploy-ssh-keys.sh
   ls -la ~/.local/state/ssh-keys.d/
   cat ~/.local/state/ssh-keys.d/agent-keys  # Should list keys to load
   ```

---

## Architecture Evolution Notes

### Current Status (v1.0)
- ✅ Keys + certificates deployed to runtime
- ✅ Certificates regenerated on every activation
- ✅ Symlink-based cert auto-loading
- ✅ Integrated with home-manager lifecycle

### Potential Future Enhancements

1. **Certificate Renewal Strategy**
   - Monitor cert expiry
   - Pre-regenerate certs before expiry
   - Alert on expired certs in use

2. **Multi-Profile Key Rotation**
   - Support dynamic profile switching
   - Isolated key sets per profile
   - Key transition workflows

3. **Hardware Token Integration**
   - Support FIDO2/YubiKey keys
   - Hybrid key + token auth

4. **Distributed CA Management**
   - External CA authority integration
   - Federated identity scenarios
   - Cross-host cert coordination

---

## Related Documentation

- [SSH Add-Keys Module](./ssh-add-keys.md) — Integration with home-manager SSH
- [SOPS Configuration](../sops-setup.md) — Secrets encryption at rest
- [Home Profile Configuration](../profiles.md) — User/host profile setup

---

## Quick Reference: Script Functions

| Script | Purpose | Input | Output | Trigger |
|--------|---------|-------|--------|---------|
| `ssh-extract-keys.sh` | Extract keys from profile YAML | Profile YAML path, output dir | Key files (private/public) | Stage 1 |
| `ssh-regenerate-certs.sh` | Generate certificates via CA signing | Profile YAML, output dir | Certificate files + symlinks | Stage 2 |
| `deploy-ssh-keys.sh` | Deploy to runtime + generate manifest | Profile name, secrets path | Keys in `~/.local/state/ssh-keys.d/` | Stage 3 |
| `ensure-authorized-keys.sh` | Ensure authorized_keys file ready | (none, uses defaults) | Mutable `~/.ssh/authorized_keys` | Stage 4 |

---

## Questions for Future Contributors

When modifying this system, consider:

1. **Where does the new logic fit?** (Extract / Regenerate / Deploy / Authorize phases)
2. **Does it touch private key material?** (If yes, ensure temp files use `chmod 400`)
3. **Should it regenerate on every activation?** (Or only on config change?)
4. **How does it affect rsync --delete logic?** (Be careful not to delete needed files)
5. **Is there a simpler way?** (Avoid complexity for edge cases)

