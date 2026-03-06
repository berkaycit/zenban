---
name: doc-sync
description: |
  Syncs agent_docs/ and logs to memory-bank.md after major changes.
  Use after: adding new feature/system, new module/component, architectural changes, new workflows, breaking changes.
  Do NOT use for: type changes, function edits, bug fixes, refactoring, single-file changes, tests.
---

# Doc Sync

Sync documentation after major code changes.

## Workflow

1. Run `git diff --staged` or `git diff HEAD~1`
2. If major change: update relevant doc section only
3. Add entry to `agent_docs/memory-bank.md`

## What is Major

**Major:** New feature/system, new module, architectural change, new workflow, breaking change affecting multiple files.

**Not major:** Type/interface edits, function changes, bug fixes, refactoring, single-file changes.

## Doc Mapping

| Area | Document |
|------|------|
| Project structure, components, data flow | agent_docs/architecture.md |
| Code patterns, naming, performance | agent_docs/conventions.md |
| App features, shortcuts, storage | agent_docs/features.md |
| Recent changes history | agent_docs/memory-bank.md |

## Rules

- Edit only relevant section concisely, never rewrite whole doc
- Keep each doc under 80 lines
- Never include code snippets or code blocks in the document; only refer to code by file/line when absolutely necessary
- Use str_replace for surgical edits

## memory-bank.md

Add after `## List`:

```markdown
- **Summary**: [<50 chars, present tense]
- **Description**: [Concise, 3-4 sentences max, what changed and why]
```
