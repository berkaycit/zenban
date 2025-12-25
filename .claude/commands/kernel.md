---
allowed-tools: Read, Glob, Grep
argument-hint: <prompt>
description: Analyze the project and generate a KERNEL-formatted prompt. No code changes, analysis only.
---

## Before Starting

Read @CLAUDE.md to understand project context.

## User Request

$ARGUMENTS

## Task

Analyze the user request above, research the relevant code/files, then generate an improved prompt using the KERNEL method.

**DO NOT make any code changes. Analysis and prompt generation only.**

## KERNEL Method

**K - Keep it simple**
- One clear goal, not 500 words of context

**E - Easy to verify**
- Clear success criteria ("include 3 examples" not "make it engaging")

**R - Reproducible results**
- No temporal references, use specific versions and exact requirements

**N - Narrow scope**
- One prompt = one goal
- Split complex tasks into chained prompts if needed

**E - Explicit constraints**
- Tell what NOT to do
- Constraints reduce unwanted outputs

**L - Logical structure**
```
Task: [What to do]
Input: [Context/files]
Constraints: [Limits, what to avoid]
Output: [Expected result]
Verify: [How to test success]
Note: You should strictly follow @CLAUDE.md rules!
```

## Output Format

Provide the KERNEL-formatted prompt that the user can use. If the task is complex, provide chained prompts (each does one thing well, feeds into the next).