---
description: Default coding agent; main model is the local 30B agent. Delegates simple tasks to local workers.
mode: primary
permissions:
  - action: subagent
    resource: "*"
    effect: deny
  - action: subagent
    resource: "local-worker"
    effect: allow
  - action: subagent
    resource: "local-small"
    effect: allow
---
