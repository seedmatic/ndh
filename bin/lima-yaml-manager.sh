#!/usr/bin/env bash
# lima-yaml-manager.sh (@codebase)
# Surgical YAML editing for Lima configuration files with managed sections
# 
# This script provides safe, inline editing of YAML files by using head/foot comment markers
# to identify sections managed by nix-darwin-home vs user-managed content.
#
# Usage:
#   ./bin/lima-yaml-manager.sh --file networks.yaml --add-network cluster1 --mode shared --gateway 10.80.8.1
#   ./bin/lima-yaml-manager.sh --file lima.yaml --update-section networks --from-json networks.json
#
# Features:
# - Uses head_comment and foot_comment markers for clear region boundaries
# - Preserves existing user content and comments outside managed regions
# - Rotating backups (.0, .1, .2) with configurable retention
# - Validates YAML syntax before committing changes
#
set -euo pipefail

# Configuration
MANAGED_HEAD_MARKER="nix-darwin-home managed START"
MANAGED_FOOT_MARKER="nix-darwin-home managed END"
MAX_BACKUPS=3

# Default values
FILE=""
ACTION=""
NETWORK_NAME=""
NETWORK_MODE=""
NETWORK_GATEWAY=""
NETWORK_NETMASK=""
NETWORK_INTERFACE=""
NETWORK_DHCP_END=""
SECTION_NAME=""
FROM_JSON=""
DRY_RUN=0
VERBOSE=0

log() {
    [ $VERBOSE -eq 1 ] && echo "[lima-yaml-manager] $*" >&2
}

usage() {
    cat << 'EOF'
Usage: lima-yaml-manager.sh [OPTIONS]

Actions:
  --add-network NAME          Add/update network definition in managed section
  --remove-network NAME       Remove network definition (if in managed section)
  --update-section SECTION    Replace managed section content from JSON
  --init-managed-section SEC  Initialize a section with head/foot comment markers

Network options (for --add-network):
  --mode MODE                 Network mode (shared, bridged, host, etc.)
  --gateway IP                Gateway IP address
  --netmask MASK              Network mask (default: 255.255.255.0)
  --interface IFACE           Interface name (for bridged mode)
  --dhcp-end IP               DHCP range end IP

Section options (for --update-section):
  --from-json FILE            JSON file containing new section data

Global options:
  --file FILE                 Target YAML file
  --max-backups N             Maximum number of rotating backups (default: 3)
  --dry-run                   Show what would be changed without modifying files
  --verbose                   Enable verbose logging
  --help                      Show this help

Examples:
  # Add a managed cluster network to networks.yaml
  lima-yaml-manager.sh --file ~/.lima/_config/networks.yaml \
    --add-network cluster1 --mode shared --gateway 10.80.8.1 --dhcp-end 10.80.15.254

  # Initialize networks section in lima.yaml for management
  lima-yaml-manager.sh --file ~/.lima/nerd-nixos/lima.yaml \
    --init-managed-section networks

  # Replace managed section with new data from Nix-generated JSON
  lima-yaml-manager.sh --file ~/.lima/nerd-nixos/lima.yaml \
    --update-section networks --from-json /tmp/lima-networks.json
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --file)
            FILE="$2"; shift 2 ;;
        --add-network)
            ACTION="add-network"; NETWORK_NAME="$2"; shift 2 ;;
        --remove-network)
            ACTION="remove-network"; NETWORK_NAME="$2"; shift 2 ;;
        --update-section)
            ACTION="update-section"; SECTION_NAME="$2"; shift 2 ;;
        --init-managed-section)
            ACTION="init-managed-section"; SECTION_NAME="$2"; shift 2 ;;
        --mode)
            NETWORK_MODE="$2"; shift 2 ;;
        --gateway)
            NETWORK_GATEWAY="$2"; shift 2 ;;
        --netmask)
            NETWORK_NETMASK="$2"; shift 2 ;;
        --interface)
            NETWORK_INTERFACE="$2"; shift 2 ;;
        --dhcp-end)
            NETWORK_DHCP_END="$2"; shift 2 ;;
        --from-json)
            FROM_JSON="$2"; shift 2 ;;
        --max-backups)
            MAX_BACKUPS="$2"; shift 2 ;;
        --dry-run)
            DRY_RUN=1; shift ;;
        --verbose)
            VERBOSE=1; shift ;;
        --help)
            usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

# Validation
if [[ -z "$FILE" || -z "$ACTION" ]]; then
    echo "Error: --file and action are required" >&2
    usage; exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
    echo "Error: yq is required but not found in PATH" >&2
    exit 1
fi

# Rotating backup functions
rotate_backups() {
    local file="$1"
    local max_backups="${2:-$MAX_BACKUPS}"
    
    # Rotate existing backups: .2 -> .3 (delete), .1 -> .2, .0 -> .1
    for (( i=max_backups-1; i>=0; i-- )); do
        if [[ -f "$file.$i" ]]; then
            if (( i == max_backups-1 )); then
                rm "$file.$i"
                log "Deleted oldest backup: $file.$i"
            else
                mv "$file.$i" "$file.$((i+1))"
                log "Rotated backup: $file.$i -> $file.$((i+1))"
            fi
        fi
    done
}

backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        rotate_backups "$file"
        cp "$file" "$file.0"
        log "Created backup: $file.0"
    fi
}

restore_backup() {
    local file="$1"
    if [[ -f "$file.0" ]]; then
        cp "$file.0" "$file"
        log "Restored from backup: $file.0"
    fi
}

cleanup_backups() {
    local file="$1"
    for (( i=0; i<MAX_BACKUPS; i++ )); do
        [[ -f "$file.$i" ]] && rm "$file.$i"
    done
    log "Cleaned up all backups for $file"
}

validate_yaml() {
    local file="$1"
    if ! yq eval -o yaml '.' "$file" >/dev/null 2>&1; then
        echo "Error: Invalid YAML syntax in $file" >&2
        return 1
    fi
    return 0
}

# Check if section is managed (has our head/foot comment markers)
is_managed_section() {
    local file="$1"
    local section="$2"
    
    if [[ ! -f "$file" ]]; then
        return 1
    fi
    
    # Check for head_comment with START marker and foot_comment with END marker
    local has_head has_foot
    has_head=$(yq eval -e ".$section | head_comment | test(\"$MANAGED_HEAD_MARKER\")" "$file" 2>/dev/null && echo "true" || echo "false")
    has_foot=$(yq eval -e ".$section | foot_comment | test(\"$MANAGED_FOOT_MARKER\")" "$file" 2>/dev/null && echo "true" || echo "false")
    
    [[ "$has_head" == "true" && "$has_foot" == "true" ]]
}

# Initialize a managed section with head/foot comment markers
init_managed_section() {
    local file="$1"
    local section="$2"
    
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "Would initialize managed section '$section' in $file with head/foot comment markers"
        return 0
    fi
    
    backup_file "$file"
    
    # Create file if it doesn't exist
    if [[ ! -f "$file" ]]; then
        echo "{}" > "$file"
    fi
    
    # Add managed section markers if they don't exist
    if ! is_managed_section "$file" "$section"; then
        # Add section with head and foot comment markers using yq
        local temp_file=$(mktemp)
        yq eval -o yaml ".$section = {} | .$section head_comment = \"$MANAGED_HEAD_MARKER\" | .$section foot_comment = \"$MANAGED_FOOT_MARKER\"" "$file" > "$temp_file"
        
        if validate_yaml "$temp_file"; then
            mv "$temp_file" "$file"
            log "Initialized managed section '$section' with head/foot markers in $file"
        else
            rm "$temp_file"
            restore_backup "$file"
            echo "Error: Failed to initialize managed section (invalid YAML generated)" >&2
            return 1
        fi
    else
        log "Managed section '$section' already exists in $file"
    fi
}

# Add or update a network definition
add_network() {
    local file="$1"
    local name="$2"
    
    if [[ -z "$NETWORK_MODE" ]]; then
        echo "Error: --mode is required for --add-network" >&2
        return 1
    fi
    
    # Default netmask
    NETWORK_NETMASK="${NETWORK_NETMASK:-255.255.255.0}"
    
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "Would add/update network '$name' in $file:"
        echo "  mode: $NETWORK_MODE"
        [[ -n "$NETWORK_GATEWAY" ]] && echo "  gateway: $NETWORK_GATEWAY"
        [[ -n "$NETWORK_NETMASK" ]] && echo "  netmask: $NETWORK_NETMASK"
        [[ -n "$NETWORK_INTERFACE" ]] && echo "  interface: $NETWORK_INTERFACE"
        [[ -n "$NETWORK_DHCP_END" ]] && echo "  dhcpEnd: $NETWORK_DHCP_END"
        return 0
    fi
    
    backup_file "$file"
    
    # Ensure file exists and has networks section
    if [[ ! -f "$file" ]]; then
        echo "networks: {}" | yq eval -o yaml '.' - > "$file"
    fi
    
    # Ensure networks section exists - handle both object and array formats
    local temp_file=$(mktemp)
    yq eval -o yaml '.networks = (.networks // {})' "$file" > "$temp_file" && mv "$temp_file" "$file"
    
    # Build network definition
    local network_def="{\"mode\": \"$NETWORK_MODE\""
    [[ -n "$NETWORK_GATEWAY" ]] && network_def+=", \"gateway\": \"$NETWORK_GATEWAY\""
    [[ -n "$NETWORK_NETMASK" ]] && network_def+=", \"netmask\": \"$NETWORK_NETMASK\""
    [[ -n "$NETWORK_INTERFACE" ]] && network_def+=", \"interface\": \"$NETWORK_INTERFACE\""
    [[ -n "$NETWORK_DHCP_END" ]] && network_def+=", \"dhcpEnd\": \"$NETWORK_DHCP_END\""
    network_def+="}"
    
    # Update network using yq with YAML output
    temp_file=$(mktemp)
    yq eval -o yaml ".networks[\"$name\"] = $network_def" "$file" > "$temp_file"
    
    if validate_yaml "$temp_file"; then
        mv "$temp_file" "$file"
        log "Added/updated network '$name' in $file"
        cleanup_backups "$file"
    else
        rm "$temp_file"
        restore_backup "$file"
        echo "Error: Failed to add network (invalid YAML generated)" >&2
        return 1
    fi
}

# Update managed section from JSON file (replaces content while preserving markers)
update_section() {
    local file="$1"
    local section="$2"
    local json_file="$3"
    
    if [[ ! -f "$json_file" ]]; then
        echo "Error: JSON file not found: $json_file" >&2
        return 1
    fi
    
    # Check if section is managed
    if ! is_managed_section "$file" "$section"; then
        echo "Error: Section '$section' is not managed (missing head/foot comment markers)" >&2
        return 1
    fi
    
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "Would update managed section '$section' from $json_file in $file"
        return 0
    fi
    
    backup_file "$file"
    
    # Update section content while preserving head/foot comment markers
    local temp_file=$(mktemp)
    yq eval -o yaml ".$section = load(\"$json_file\") | .$section head_comment = \"$MANAGED_HEAD_MARKER\" | .$section foot_comment = \"$MANAGED_FOOT_MARKER\"" "$file" > "$temp_file"
    
    if validate_yaml "$temp_file"; then
        mv "$temp_file" "$file"
        log "Updated managed section '$section' from $json_file in $file"
    else
        rm "$temp_file"
        restore_backup "$file"
        echo "Error: Failed to update section (invalid YAML generated)" >&2
        return 1
    fi
}

# Main execution
case "$ACTION" in
    "init-managed-section")
        init_managed_section "$FILE" "$SECTION_NAME"
        ;;
    "add-network")
        add_network "$FILE" "$NETWORK_NAME"
        ;;
    "remove-network")
        if [[ $DRY_RUN -eq 1 ]]; then
            echo "Would remove network '$NETWORK_NAME' from managed section in $FILE"
        else
            # Only remove if in managed section
            if is_managed_section "$FILE" "networks"; then
                backup_file "$FILE"
                temp_file=$(mktemp)
                # Remove network while preserving head/foot comments on networks section
                yq eval -o yaml "del(.networks[\"$NETWORK_NAME\"]) | .networks head_comment = \"$MANAGED_HEAD_MARKER\" | .networks foot_comment = \"$MANAGED_FOOT_MARKER\"" "$FILE" > "$temp_file"
                if validate_yaml "$temp_file"; then
                    mv "$temp_file" "$FILE"
                    log "Removed network '$NETWORK_NAME' from managed section in $FILE"
                else
                    rm "$temp_file"
                    restore_backup "$FILE"
                    echo "Error: Failed to remove network" >&2
                    exit 1
                fi
            else
                echo "Error: networks section is not managed, cannot remove network" >&2
                exit 1
            fi
        fi
        ;;
    "update-section")
        if [[ -z "$FROM_JSON" ]]; then
            echo "Error: --from-json is required for --update-section" >&2
            exit 1
        fi
        update_section "$FILE" "$SECTION_NAME" "$FROM_JSON"
        ;;
    *)
        echo "Error: Unknown action: $ACTION" >&2
        usage
        exit 1
        ;;
esac

log "Operation completed successfully"