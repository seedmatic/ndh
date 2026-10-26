#!/usr/bin/env -S bash -euo pipefail
source @nixBashTrampoline@
# ops: the operator's one entry point to the fabric's pending steps (roles × keys K2). The queue is fixed at build
# time from keys.yaml (queue.nix), so what `ops next` shows is what the switch installed, never an argument.
#   ops next    the queue's head: what it would do, on which machines in which order, and its preconditions
#   ops queue   the whole queue, and the keys that wait for a declaration
# Read-only in K2: it changes nothing, runs nothing and asks nothing. K4 and K6 add the steps that act.
PATH="@toolPath@:/usr/bin:/bin"
queue="@queue@"
keysReconcile="@keysReconcile@"
ndhOps="@ndhOps@"

usage() {
  echo "usage: ops next | ops queue" >&2
  exit 2
}

# One entry: its machines, what it does, and each precondition met, unmet or not verified.
show() { # $1 = the jq path of an entry list
  yq -r -p json -o json "$1"' | .[] |
    "  • " + .machine + " — " + .does + "\n"
    + ((.checked | map("      ✗ unmet: " + .)) + (.unchecked | map("      ? not verified: " + .)) | join("\n"))
  ' "$queue"
}

next() {
  : "the queue's head: the earliest step of the batch, its machines in fleet-switch's order"
  if [[ $(yq -p json -o json '.head | length' "$queue") == 0 ]]; then
    : "an empty head: no slot born on a machine waits for a step"
    echo "nothing to do"
    return 0
  fi
  local step
  step=$(yq -r -p json -o json '.head[0].step' "$queue")
  echo "next step: $step, in fleet-switch's order:"
  show '.head'
  : "a precondition read in the declaration and unmet refuses the step; an unmeasured one is shown, never met"
  if [[ $(yq -p json -o json '[.head[].checked[]] | length' "$queue") != 0 ]]; then
    echo "refused: a condition is unmet (✗ above)."
    return 0
  fi
  case $step in
    generate)
      : "the machines generate at their switch (🎛️); the window opens once keys-reconcile plan measures every one"
      echo "measuring the publications (keys-reconcile plan, read-only):"
      if ! "$keysReconcile" plan; then
        echo "the window waits: switch the machines not ready (🎛️), then run ops next again."
        return 0
      fi
      : "ready: the window, through the operator's armed delegation; it measures again and asks the one « yes »"
      "$ndhOps" keys-reconcile window
      ;;
    serve)
      echo "for 🎛️: switch these machines (fleet-switch), in this order; ops switches nothing."
      ;;
  esac
}

list() {
  : "the whole queue: the head, the later steps it blocks, and the keyring slots that wait for a declaration"
  next
  if [[ $(yq -p json -o json '.blocked | length' "$queue") != 0 ]]; then
    echo "then:"
    show '.blocked'
  fi
  if [[ $(yq -p json -o json '.waiting | length' "$queue") != 0 ]]; then
    echo "waiting for a declaration (never offered by ops next):"
    yq -r -p json -o json '.waiting[] | "  • " + .machine + " — " + .key + "@" + .slot + " (" + .state + ", born in the keyring)"' "$queue"
  fi
}

main() {
  : "ops reads the queue the switch froze from keys.yaml; it changes, runs and asks nothing"
  [[ -r $queue ]] || {
    echo "ops: refused: the installed queue is unreadable ($queue)" >&2
    exit 1
  }
  yq -e -p json -o json '(.head | type) == "!!seq" and (.blocked | type) == "!!seq" and (.waiting | type) == "!!seq"' \
    "$queue" >/dev/null 2>&1 || {
    echo "ops: refused: the installed queue is malformed ($queue)" >&2
    exit 1
  }
  (($# == 1)) || usage
  case $1 in
    next) next ;;
    queue) list ;;
    *) usage ;;
  esac
}

ndh::logger:command:run "@loggerTag@" main "$@"
