---
allowed-tools: Read, Edit, Bash(npm run test:*)
description: Write unit tests for the specified code
---

## Before Starting

Read @CLAUDE.md and follow all Rules.

## Stack

Vitest, React Testing Library, TypeScript

## Task

Write unit tests for the specified code:

1. Test happy path (expected behavior)
2. Test edge cases (empty, null, boundary values)
3. Test error cases (invalid inputs, failures)

## Guidelines

- Keep tests simple and readable
- One assertion per test when possible
- Use descriptive test names
- Mock external dependencies (localStorage, APIs)
- Don't test implementation details, test behavior
- For components: test user interactions, not internal state

## After Writing

Run tests to verify:
```bash
npm run test
```
