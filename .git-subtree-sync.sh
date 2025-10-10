#!/usr/bin/env bash
# Git Subtree Management Helper
# Manages multiple subtree integrations

set -e

# Define subtrees: name -> prefix:remote:branch
declare -A SUBTREES=(
  [rke2]="modules/nixos/incus-rke2-cluster:../incus-rke2-cluster:main"
  [headscale]="modules/nixos/incus-headscale:../incus-headscale:main"
)

# Parse subtree info
get_subtree_info() {
  local name=$1
  local info=${SUBTREES[$name]}
  if [ -z "$info" ]; then
    echo "Error: Unknown subtree '$name'"
    echo "Available subtrees: ${!SUBTREES[@]}"
    exit 1
  fi
  IFS=':' read -r prefix remote branch <<< "$info"
}

# Get subtree name or default to all
SUBTREE_NAME="${2:-all}"

case "${1:-help}" in
  pull)
    if [ "$SUBTREE_NAME" = "all" ]; then
      for name in "${!SUBTREES[@]}"; do
        echo "=== Pulling $name subtree ==="
        get_subtree_info "$name"
        git subtree pull --prefix="$prefix" "$remote" "$branch" --squash
      done
      echo "✅ All subtrees updated from upstream"
    else
      get_subtree_info "$SUBTREE_NAME"
      echo "=== Pulling changes from $remote into subtree ==="
      git subtree pull --prefix="$prefix" "$remote" "$branch" --squash
      echo "✅ Subtree $SUBTREE_NAME updated from upstream"
    fi
    ;;
  
  push)
    if [ "$SUBTREE_NAME" = "all" ]; then
      echo "Error: Please specify a subtree name for push (safety measure)"
      echo "Available: ${!SUBTREES[@]}"
      exit 1
    fi
    get_subtree_info "$SUBTREE_NAME"
    echo "=== Pushing subtree changes back to $remote ==="
    git subtree push --prefix="$prefix" "$remote" "$branch"
    echo "✅ Changes pushed to upstream for $SUBTREE_NAME"
    ;;
  
  status)
    if [ "$SUBTREE_NAME" = "all" ]; then
      for name in "${!SUBTREES[@]}"; do
        get_subtree_info "$name"
        echo "=== Subtree: $name ==="
        echo "  Prefix: $prefix"
        echo "  Remote: $remote"
        echo "  Branch: $branch"
        echo "  Recent commits:"
        git log --oneline --graph -- "$prefix" | head -5 | sed 's/^/    /'
        echo ""
      done
    else
      get_subtree_info "$SUBTREE_NAME"
      echo "=== Subtree: $SUBTREE_NAME ==="
      echo "Prefix: $prefix"
      echo "Remote: $remote"
      echo "Branch: $branch"
      echo ""
      echo "Recent commits in subtree:"
      git log --oneline --all --graph -- "$prefix" | head -10
    fi
    ;;
  
  help|*)
    cat <<EOF
Git Subtree Management for Multiple Subtrees

Usage: $0 <command> [subtree-name]

Commands:
  pull [name]   Pull changes from upstream (default: all)
  push <name>   Push subtree changes back to upstream (requires name)
  status [name] Show subtree information (default: all)
  help          Show this help message

Available Subtrees:
  rke2       - incus-rke2-cluster (RKE2 Kubernetes deployment)
  headscale  - incus-headscale (Headscale VPN server/gateway)

Examples:
  $0 pull               # Pull all subtrees
  $0 pull rke2          # Pull only rke2 subtree
  $0 push headscale     # Push headscale changes back
  $0 status             # Show status of all subtrees
  $0 status rke2        # Show status of rke2 subtree

Workflow:
  1. Work in ../incus-rke2-cluster or ../incus-headscale for focused development
  2. Run '$0 pull' to sync changes into this repo
  3. Work in modules/nixos/incus-* for integration
  4. Run '$0 push <name>' to sync integration improvements back (optional)

Manual Commands:
  Pull:  git subtree pull --prefix=<prefix> <remote> <branch> --squash
  Push:  git subtree push --prefix=<prefix> <remote> <branch>
EOF
    ;;
esac
