---
allowed-tools: Bash(git diff:*), Bash(git status:*), Read, Edit
description: Add entry to memory-bank.md based on recent changes
---

## Context

- Git status: !`git status --short`
- Recent changes: !`git diff HEAD~1 --stat`

## Task

Based on the changes above, add a new entry to `agent_docs/memory-bank.md` after `## List`:

```markdown
- **Summary**: [<50 chars, present tense]
- **Description**: [Concise, 3-4 sentences max, what changed and why]
```
