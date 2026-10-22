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

# One entry, in French: its machines, what it does, and each precondition met, unmet or not verified.
show() { # $1 = the jq path of an entry list
  yq -r -p json -o json "$1"' | .[] |
    "  • " + .machine + " — " + .does + "\n"
    + ((.checked | map("      ✗ non remplie : " + .)) + (.unchecked | map("      ? non vérifié : " + .)) | join("\n"))
  ' "$queue"
}

next() {
  : "the queue's head: the earliest step of the batch, its machines in fleet-switch's order"
  if [[ $(yq -p json -o json '.head | length' "$queue") == 0 ]]; then
    : "an empty head: no slot born on a machine waits for a step"
    echo "rien à faire"
    return 0
  fi
  local step
  step=$(yq -r -p json -o json '.head[0].step' "$queue")
  echo "prochain pas : $step, dans l'ordre de fleet-switch :"
  show '.head'
  : "a precondition read in the declaration and unmet refuses the step; an unmeasured one is shown, never met"
  if [[ $(yq -p json -o json '[.head[].checked[]] | length' "$queue") != 0 ]]; then
    echo "refusé : une condition n'est pas remplie (✗ ci-dessus)."
    return 0
  fi
  case $step in
    generate)
      : "the machines generate at their switch (🎛️); the window opens once keys-reconcile plan measures every one"
      echo "mesure des publications (keys-reconcile plan, lecture seule) :"
      if ! "$keysReconcile" plan; then
        echo "la fenêtre attend : basculer les machines non prêtes (🎛️), puis relancer ops next."
        return 0
      fi
      : "ready: the window, through the operator's armed delegation; it measures again and asks the one « oui »"
      "$ndhOps" keys-reconcile window
      ;;
    serve)
      echo "à faire par 🎛️ : basculer ces machines (fleet-switch), dans cet ordre ; ops ne bascule rien."
      ;;
  esac
}

list() {
  : "the whole queue: the head, the later steps it blocks, and the keyring slots that wait for a declaration"
  next
  if [[ $(yq -p json -o json '.blocked | length' "$queue") != 0 ]]; then
    echo "ensuite :"
    show '.blocked'
  fi
  if [[ $(yq -p json -o json '.waiting | length' "$queue") != 0 ]]; then
    echo "en attente d'une déclaration (jamais proposées par ops next) :"
    yq -r -p json -o json '.waiting[] | "  • " + .machine + " — " + .key + "@" + .slot + " (" + .state + ", née dans le trousseau)"' "$queue"
  fi
}

main() {
  : "ops reads the queue the switch froze from keys.yaml; it changes, runs and asks nothing"
  [[ -r $queue ]] || {
    echo "ops: refusé : la file installée est illisible ($queue)" >&2
    exit 1
  }
  yq -e -p json -o json '(.head | type) == "!!seq" and (.blocked | type) == "!!seq" and (.waiting | type) == "!!seq"' \
    "$queue" >/dev/null 2>&1 || {
    echo "ops: refusé : la file installée est mal formée ($queue)" >&2
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
