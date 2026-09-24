---
# Managed by @plainconceptsplatform/workflows@0.5.1. Source: loops/stacks/node-pnpm/pack.yml. Profile digest: 08448fbaf1f8. Update with `workflows update --force`; consumer edits may be overwritten.
network:
  allowed:
    - defaults
    - node
pre-agent-steps:
  - name: Set up pnpm
    uses: pnpm/action-setup@ea17c68df8912ef543352723c149a84f56e3d413
  - name: Set up Node for pnpm
    uses: actions/setup-node@820762786026740c76f36085b0efc47a31fe5020
---

Setup for the node-pnpm toolchain. Ecosystem facts only: this file carries no
architectural rule, no house style and no document naming convention, and none of
the frontmatter keys that do not merge from an import.
