# Agent Guidelines

This file defines how AI coding agents should operate in this repository.

## Skills

Skills are located in `.agents/skills/` and must be loaded with the full instructions from their `SKILL.md` before performing related tasks.

### Project Management → `github-scrum`

Use the `.agents/skills/github-scrum/SKILL.md` skill for all project management tasks:

- Planning and prioritizing features or fixes
- Managing the Product Backlog as GitHub Issues
- Running Sprints as GitHub Milestones
- Tracking progress and closing completed work

### Code Development → `methodical-programming`

Use the `.agents/skills/methodical-programming/SKILL.md` skill for all code development tasks:

- Implementing new features or fixing bugs
- Deriving correct implementations from specifications
- Reasoning about correctness, invariants, and edge cases
- Refactoring and reviewing existing code

### Documentation → `pragmatic-docs`

Use the `.agents/skills/pragmatic-docs/SKILL.md` skill for all documentation tasks:

- Writing or improving `README.md`
- Creating guides, module docs, or `CONTRIBUTING.md`
- Structuring any project documentation

## General Rules

- Always read the relevant skill's `SKILL.md` before starting a task in its domain.
- Keep changes focused and incremental.
- Prefer clarity and correctness over cleverness.
