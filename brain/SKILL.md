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

The output above is from the /brain command, which has already done what the user asked. Show the user that
output as it is (but if it ends with a project brain's STATUS, say in one line which brain is now in use instead of
repeating the STATUS), then stop: run no tools. If it printed a STATUS, that is this session's project brain from
now on, in place of any loaded earlier; if it chose no brain, disregard any project STATUS loaded earlier.
