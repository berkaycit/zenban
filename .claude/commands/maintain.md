---
allowed-tools: Read, Edit, Bash(git diff:*), Bash(git status:*), Bash(npm run lint:*), Bash(npm run format:*)
description: Refactor recent changes for maintainability, understandability, robustness, and flexibility
---

## Context

Run `git diff --staged` or `git diff HEAD~1` to see recent changes.

## Before Starting

Read @CLAUDE.md and follow all Rules strictly.
Read @agent_docs/architecture.md to understand project structure.

## Task

Analyze the recent changes above and refactor to improve:

1. **Maintainability**: Clear structure, single responsibility, easy to modify
2. **Understandability**: Descriptive names, logical flow, minimal complexity
3. **Robustness**: Edge case handling, proper error boundaries, defensive coding
4. **Flexibility**: Extensible patterns, loose coupling, reusable components

## Naming & Organization

- **No generic names**: Avoid names like `Manager`, `Handler`, `Data`, `Item` without context
- **Descriptive & extensible**: Names should describe purpose and allow future additions without conflict
- **Correct folder placement**: Verify files are in appropriate directories per architecture.md
- **Consistent patterns**: Follow existing naming conventions in the codebase

## Core Principle

**Less code is better.** Deleting code is more valuable than adding code (without breaking features).

- Fewer lines = fewer bugs, easier to understand
- Code should be minimal AND readable (not clever/cryptic)
- If you can remove code while preserving functionality, do it
- Remove duplicate code and make it reusable

## Constraints

- Follow all rules from CLAUDE.md
- Make only necessary changes
- Keep solutions simple and focused
- Preserve existing functionality
- Verify changes are easy to understand

## Avoid

- **Premature optimization**: Don't optimize unless there's a proven need
- **Over-engineering**: Don't create abstractions, classes, or patterns "just in case"
- **Unnecessary indirection**: Don't add layers that don't solve a current problem

Only refactor what is needed now. Simple, working code is better than clever, over-architected code.

## After Refactoring

1. Run lint and format (tools handle the fixes, don't spend time on style issues):
```bash
npm run lint
npm run format
```

2. Update `@agent_docs/architecture.md` (only relevant sections, no added detail).
   Never include code snippets or code blocks in the document; only refer to code by file/line when absolutely necessary.