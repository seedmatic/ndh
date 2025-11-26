#!/bin/bash
# Network monitor main check script (templated via substituteAll)
set -euo pipefail
LOG="/var/log/network-monitor.log"
{
  echo "[$(date)] Network monitor check start (mode: @mode@)"

  check_interface() {
    local iface="$1"
    if ifconfig "$iface" >/dev/null 2>&1; then
      local status=$(ifconfig "$iface" | grep "status:" | awk '{print $2}')
      local has_ip=0
      if ifconfig "$iface" | grep -q "inet "; then
        has_ip=1
      fi
      echo "$status:$has_ip"
    else
      echo "not_found:0"
    fi
  }

  manage_bonded_network() {
    echo "[$(date)] Checking bonded network (@bondInterface@)"

    if ! ifconfig "@bondInterface@" >/dev/null 2>&1; then
      echo "[$(date)] Bond interface @bondInterface@ not found"
      return
    fi

    if ! ipconfig getifaddr "@bondInterface@" >/dev/null 2>&1; then
      echo "[$(date)] Bond @bondInterface@ has no IP, restoring DHCP..."
      ipconfig set "@bondInterface@" DHCP
    fi

    for bridge in $(ifconfig -l | tr ' ' '\n' | grep '^bridge'); do
      if netstat -rn | grep -q "^default.*$bridge"; then
        echo "[$(date)] Removing default route from Lima bridge $bridge"
        route -n delete default -ifscope "$bridge" 2>/dev/null || true
      fi
    done

    if netstat -rn | grep -q "^default.*en1"; then
      echo "[$(date)] Removing Wi-Fi default route (bond takes priority)"
      route -n delete default -ifscope en1 2>/dev/null || true
    fi
  }

  manage_individual_interfaces() {
    echo "[$(date)] Checking individual interface priorities"

    local primary="@primaryInterface@"
    local backup="@backupInterface@"
    local primary_status=$(check_interface "$primary")
    echo "[$(date)] Primary interface $primary status: $primary_status"

    case "$primary_status" in
      "active:1")
        local primary_gateway=$(netstat -rn | grep "^default.*$primary" | awk '{print $2}' | head -1)
        if [ -n "$primary_gateway" ]; then
          echo "[$(date)] Reasserting primary route via $primary (metric @routeMetricPrimary@)"
          route -n delete default -ifscope "$primary" 2>/dev/null || true
          route -n add default "$primary_gateway" -ifscope "$primary" -hopcount @routeMetricPrimary@ 2>/dev/null || true
        else
          echo "[$(date)] Primary $primary active but missing default route, renewing DHCP"
          ipconfig set "$primary" DHCP
          sleep 2
        fi

@secondaryRouteStatements@

        if [ "$backup" != "$primary" ] && if ifconfig "$backup" >/dev/null 2>&1; then
          local backup_gateway=$(netstat -rn | grep "^default.*$backup" | awk '{print $2}' | head -1)
          if [ -n "$backup_gateway" ]; then
            echo "[$(date)] Configuring backup $backup with metric @routeMetricBackup@"
            route -n delete default -ifscope "$backup" 2>/dev/null || true
            route -n add default "$backup_gateway" -ifscope "$backup" -hopcount @routeMetricBackup@ 2>/dev/null || true
          fi
        fi
        ;;

      "active:0"|"inactive:0")
        echo "[$(date)] Primary $primary unavailable, promoting backup $backup"
        if ifconfig "$backup" >/dev/null 2>&1; then
          ifconfig "$backup" up 2>/dev/null || true
          local backup_status=$(check_interface "$backup")
          if [ "$backup_status" != "active:1" ]; then
            ipconfig set "$backup" DHCP
            sleep 2
          fi
          local backup_gateway=$(netstat -rn | grep "^default.*$backup" | awk '{print $2}' | head -1)
          if [ -n "$backup_gateway" ]; then
            echo "[$(date)] Setting $backup as primary route (metric @routeMetricPrimary@)"
            route -n delete default -ifscope "$backup" 2>/dev/null || true
            route -n add default "$backup_gateway" -ifscope "$backup" -hopcount @routeMetricPrimary@ 2>/dev/null || true
          fi
        fi
        ;;
    esac

    for bridge in $(ifconfig -l | tr ' ' '\n' | grep '^bridge'); do
      if netstat -rn | grep -q "^default.*$bridge"; then
        echo "[$(date)] Removing default route from Lima bridge $bridge"
        route -n delete default -ifscope "$bridge" 2>/dev/null || true
      fi
    done
  }

  if [ "@mode@" = "bonded" ]; then
    manage_bonded_network
  else
    manage_individual_interfaces
  fi

  echo "[$(date)] Network monitor check complete"
} >>"$LOG" 2>&1
