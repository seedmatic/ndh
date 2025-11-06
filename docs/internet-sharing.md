# Internet Sharing Module

## Overview

The `internet-sharing.nix` Darwin module provides declarative configuration of macOS Internet Sharing for Lima VM bridge networks. It automates the creation and maintenance of `/Library/Preferences/SystemConfiguration/com.apple.nat.plist`, which controls Internet Sharing behavior on macOS.

## Why Internet Sharing?

When running Incus containers on a Lima VM using **macvlan networking**, containers bypass the Lima VM's routing stack at Layer 2 (L2). This means:

1. Container packets go directly from the container → Lima bridge (vmwan0) → macOS bridge (bridge101) → WAN
2. The Lima VM's nftables NAT rules never see these packets (they're bypassed via macvlan)
3. Traditional pf NAT on macOS fails because the routing table has a direct route (`10.80.16.0/21 dev bridge101`) preventing NAT path

**Solution**: macOS Internet Sharing creates `com.apple.internet-sharing` pf anchors that provide automatic NAT for the bridge network, just like sharing internet from WiFi to Ethernet. This is the same mechanism that makes containers work on the `bioskop` host.

## Architecture

### Plist Configuration

The module writes configuration to `/Library/Preferences/SystemConfiguration/com.apple.nat.plist`:

```xml
<dict>
  <key>NAT</key>
  <dict>
    <key>Enabled</key>
    <true/>
    <key>PrimaryInterface</key>
    <string>en0</string>
    <key>SharingDevices</key>
    <array>
      <string>bridge101</string>
    </array>
  </dict>
</dict>
```

### PF Anchors Created

When Internet Sharing is active, it creates these pf anchors:
- `nat-anchor "com.apple.internet-sharing"`
- `rdr-anchor "com.apple.internet-sharing"`

These anchors provide automatic NAT translation for traffic from `bridge101` to `en0`.

## Usage

### Basic Configuration

Add to your host's `flake.nix`:

```nix
internetSharing = {
  enable = true;
  primaryInterface = "en0";
  sharingDevices = [ "bridge101" ];
};
```

### Full Configuration Options

```nix
internetSharing = {
  # Enable Internet Sharing NAT
  enable = true;
  
  # WAN interface with upstream internet (typically en0)
  primaryInterface = "en0";
  
  # Bridge interfaces to share internet to (Lima VM bridges)
  sharingDevices = [ "bridge101" ];
  
  # Attempt to restart NetworkSharing daemon (will fail with SIP)
  autoToggle = false;
  
  # Verify pf anchors are active after activation
  verifyAnchors = true;
};
```

## Manual Activation Required

**Important**: Due to System Integrity Protection (SIP), the NetworkSharing daemon cannot be restarted programmatically. After running `darwin-rebuild switch`, you must **manually toggle Internet Sharing** in System Settings:

1. Go to **System Settings → General → Sharing**
2. Click **Internet Sharing** in left sidebar
3. Configure:
   - Share your connection from: **en0** (or your WAN interface)
   - To computers using: Check **bridge101**
4. Toggle Internet Sharing **OFF** then **ON**

This one-time manual toggle causes the NetworkSharing daemon to read the new plist configuration and create the necessary pf anchors.

## Verification

### Check Plist Configuration

```bash
sudo defaults read /Library/Preferences/SystemConfiguration/com.apple.nat
```

Expected output:
```
{
    NAT = {
        Enabled = 1;
        PrimaryInterface = en0;
        SharingDevices = (bridge101);
    };
}
```

### Verify PF Anchors Active

```bash
sudo pfctl -s nat | grep internet-sharing
```

Expected output:
```
nat-anchor "com.apple.internet-sharing" all
rdr-anchor "com.apple.internet-sharing" all
```

### Check Anchor Statistics

```bash
sudo pfctl -s nat -v | grep -A5 internet-sharing
```

You should see evaluations incrementing as traffic passes through.

### Test Container Connectivity

```bash
# From Lima VM, test container internet access
ssh lima-nerd-nixos 'incus exec master -- curl -4 -s https://ifconfig.me --max-time 3'
```

Should return your public WAN IP (NAT translated).

## Troubleshooting

### Anchors Not Appearing

If `pfctl -s nat` doesn't show internet-sharing anchors:

1. Verify NetworkSharing daemon is running:
   ```bash
   sudo launchctl list | grep NetworkSharing
   ```

2. Check plist configuration is correct:
   ```bash
   sudo defaults read /Library/Preferences/SystemConfiguration/com.apple.nat
   ```

3. **Manually toggle Internet Sharing** in System Settings (OFF then ON)

### Containers Still Have No Internet

1. Verify IP forwarding enabled:
   ```bash
   sysctl net.inet.ip.forwarding  # should be 1
   ```

2. Check routing on macOS:
   ```bash
   netstat -rn | grep 10.80
   ```
   
   Should show route via bridge101.

3. Verify Lima VM can reach internet:
   ```bash
   ssh lima-nerd-nixos 'curl -4 -s https://ifconfig.me'
   ```

4. Check macvlan interface in container:
   ```bash
   ssh lima-nerd-nixos 'incus exec master -- ip addr show eth0'
   ```

### Logs

Check activation logs:
```bash
tail -f /var/log/darwin-internet-sharing.log
tail -f /var/log/darwin-activation.log
```

## Persistence Across Reboots

Internet Sharing configuration persists across reboots once enabled. However, the GUI toggle state may reset. After a reboot:

1. Check if anchors are still active: `sudo pfctl -s nat | grep internet-sharing`
2. If missing, toggle Internet Sharing OFF then ON in System Settings

The module ensures the plist configuration is always correct on every `darwin-rebuild switch`, but the GUI toggle is the activation trigger.

## Comparison with Manual pf NAT

| Approach | Pros | Cons |
|----------|------|------|
| **Internet Sharing** | • Automatic pf anchor creation<br>• Works with macvlan L2 bypass<br>• Proven solution (bioskop uses it)<br>• Simple configuration | • Requires manual GUI toggle<br>• Less control over NAT rules |
| **Manual pf NAT** | • Full control over NAT rules<br>• No GUI dependency | • Ineffective with macvlan bypass<br>• Routing table prevents NAT path<br>• More complex configuration |

Internet Sharing is the **recommended approach** for Lima VM bridge networks using macvlan.

## See Also

- [Network Architecture Documentation](./network-setup.adoc)
- [Lima Configuration Module](../modules/darwin/lima-config.nix)
- [Diagnostic Script](../bin/bioskop-network-diagnose.sh)
