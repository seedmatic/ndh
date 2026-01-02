#!/usr/bin/env -S bash -xeuo pipefail
LOG="/var/log/network-bond-activation.log"
{
  echo "[bond] Configuring network bond interface"

@activationInterfaceChecks@

  BOND_EXISTS=0
  if ifconfig bond0 >/dev/null 2>&1; then
    BOND_EXISTS=1
  fi

  if [ "$BOND_EXISTS" -eq 1 ]; then
    CURRENT_MEMBERS=$(ifconfig bond0 | awk '/bond interfaces:/ {for(i=3;i<=NF;i++) print $i}' | sort | tr '\n' ' ' | xargs)
    DESIRED_MEMBERS=$(printf '%s\n' @bondInterfaces@ | sort | tr '\n' ' ' | xargs)

    BOND_HAS_IP=0
    if ipconfig getifaddr bond0 >/dev/null 2>&1; then
      BOND_HAS_IP=1
    fi

    if [ "$CURRENT_MEMBERS" = "$DESIRED_MEMBERS" ] && [ "$BOND_HAS_IP" -eq 1 ]; then
      echo "[bond] Bond configuration unchanged and has IP, skipping"
      exit 0
    else
      if [ "$CURRENT_MEMBERS" != "$DESIRED_MEMBERS" ]; then
        echo "[bond] Bond configuration changed, reconfiguring..."
      else
        echo "[bond] Bond exists but has no IP, reconfiguring..."
      fi
@bondDetach@
      ifconfig bond0 destroy || true
    fi
  fi

  echo "[bond] Creating bond interface with mode @bondMode@"

@releaseInterfaces@
  ifconfig bond0 create || true

@bondAttach@
@releaseInterfaces@
  ifconfig bond0 bondmode @bondMode@
  ifconfig bond0 up

@dhcpActivationBlock@

  echo "[bond] Bond interface configured successfully"
} >>"$LOG" 2>&1
