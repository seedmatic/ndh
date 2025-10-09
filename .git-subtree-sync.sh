#!/usr/bin/env bash
# Git Subtree Management Helper
# Manages the incus-rke2-cluster subtree integration

set -e

SUBTREE_PREFIX="modules/nixos/incus-rke2-cluster"
REMOTE_REPO="../incus-rke2-cluster"
REMOTE_BRANCH="main"

case "${1:-help}" in
  pull)
    echo "=== Pulling changes from $REMOTE_REPO into subtree ==="
    git subtree pull --prefix="$SUBTREE_PREFIX" "$REMOTE_REPO" "$REMOTE_BRANCH" --squash
    echo "✅ Subtree updated from upstream"
    ;;
  
  push)
    echo "=== Pushing subtree changes back to $REMOTE_REPO ==="
    git subtree push --prefix="$SUBTREE_PREFIX" "$REMOTE_REPO" "$REMOTE_BRANCH"
    echo "✅ Changes pushed to upstream"
    ;;
  
  status)
    echo "=== Subtree Information ==="
    echo "Prefix: $SUBTREE_PREFIX"
    echo "Remote: $REMOTE_REPO"
    echo "Branch: $REMOTE_BRANCH"
    echo ""
    echo "Recent commits in subtree:"
    git log --oneline --all --graph -- "$SUBTREE_PREFIX" | head -10
    ;;
  
  help|*)
    cat <<EOF
Git Subtree Management for incus-rke2-cluster

Usage: $0 <command>

Commands:
  pull    Pull changes from ../incus-rke2-cluster into this repo
  push    Push subtree changes back to ../incus-rke2-cluster
  status  Show subtree information and recent commits
  help    Show this help message

Workflow:
  1. Work in ../incus-rke2-cluster for RKE2-specific development
  2. Run '$0 pull' to sync changes into this repo
  3. Work in $SUBTREE_PREFIX for integration
  4. Run '$0 push' to sync integration improvements back (optional)

Manual Commands:
  Pull:  git subtree pull --prefix=$SUBTREE_PREFIX $REMOTE_REPO $REMOTE_BRANCH --squash
  Push:  git subtree push --prefix=$SUBTREE_PREFIX $REMOTE_REPO $REMOTE_BRANCH
EOF
    ;;
esac
