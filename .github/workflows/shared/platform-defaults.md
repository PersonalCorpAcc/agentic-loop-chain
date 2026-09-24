---
# Managed by @plainconceptsplatform/workflows@0.5.1. Source: loops/workflows/shared/platform-defaults.md. Profile digest: 08448fbaf1f8. Update with `workflows update --force`; consumer edits may be overwritten.
description: Shared network and safe-output defaults for catalog agent workflows.

network:
  allowed:
    - defaults
    - api.anthropic.com
    - node
    - github
    - dotnet
    - fonts
    - login.microsoftonline.com

safe-outputs:
  threat-detection: false
---

## Where this repository's capabilities live

This repository's skills and commands come from its agent kit, not from your engine. Every one
this prompt names, and every one those files name in turn, is a file at
`.agents/skills/<name>/SKILL.md`, with a command wrapper at `.opencode/commands/<name>.md`.

Invoke a command or load a skill by name as you normally would. When your engine does not
recognise the name -- an unknown command, an unknown skill -- do not stop and do not improvise
the procedure: read `.agents/skills/<name>/SKILL.md` and follow every step in it, treating the
text that followed the command as that file's `$ARGUMENTS`. Do the same for each skill the file
tells you to load. Reading the file is the same instruction, not a lesser substitute for it.
