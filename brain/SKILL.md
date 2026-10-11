---
name: brain
description: List, pick or register the project brain this Claude Code window uses (named brains of the context-discipline skill).
disable-model-invocation: true
argument-hint: "[<name> | none | add <name> [folder] | new <name> <folder> | rename <old> <new> | remove <name> | help]"
allowed-tools:
  - Bash(bash "${CLAUDE_SKILL_DIR}/../context-discipline/scripts/brain.sh")
  - Bash(bash "${CLAUDE_SKILL_DIR}/../context-discipline/scripts/brain.sh" *)
---
!`bash "${CLAUDE_SKILL_DIR}/../context-discipline/scripts/brain.sh" $ARGUMENTS`

The /brain command above has already done what the user asked. Relay its output to the user as it is; when it ends
with a project brain's STATUS, give one line naming the brain now in use in place of that STATUS. Then end your turn.
A STATUS printed here is this session's project brain from now on, replacing any loaded earlier; when the command
chose no brain, the session has none.
