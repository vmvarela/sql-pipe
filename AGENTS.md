# Agent Instructions

## Skills

Load the appropriate skill before starting work based on context. Skills live in `.agents/skills/` (repo-local) and `~/.agents/skills/` (global).

| When... | Load skill |
|---------|-----------|
| Reading or writing any `.zig` file | `zig-best-practices` |
| Managing issues, milestones, sprints, labels, or PRs on GitHub | `github-scrum` (`.agents/skills/github-scrum`) |
| Writing or improving documentation (`.md` files, `docs/`, README, CONTRIBUTING) | `pragmatic-docs` (`.agents/skills/pragmatic-docs`) |
| Designing algorithms, deriving programs from specifications, or formal verification | `methodical-programming` (`.agents/skills/methodical-programming`) |

### Notes

- `zig-best-practices` applies to **all Zig work** in this repo: implementation, tests, refactors, and code review.
- `github-scrum` defines the label system, milestone conventions, and sprint workflow used in this project — consult it before creating or updating any GitHub artifact.
- When multiple skills apply (e.g. writing a Go algorithm with formal derivation), load both.

## Pre-commit checklist

Run **both** of the following before every commit. Fix all failures before committing.

```bash
# 1. Unit tests (using std.testing.allocator for leak detection)
zig build test

# 2. Linter
ziglint src build.zig
```

## Conventions

- Branch names: `issue-{number}/{short-description}`
- Commits: [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `ci:`, `chore:`, `docs:`, etc.)
- PRs: squash merge, delete branch after merge
- Labels follow the Scrum label system (`type:*`, `priority:*`, `size:*`, `status:*`) — see `github-scrum` skill for details
- When closing/merging a PR, remove the `status:*` label from the linked issue (status labels are transient workflow state, not permanent metadata)

## Publishing releases

When asked to publish a release (e.g. as part of Sprint Review):

1. **Fetch the current draft** with `gh api repos/{owner}/{repo}/releases` and read the auto-generated body from Release Drafter.
2. **Rewrite the release notes** — do not keep the auto-generated output as-is:
   - Remove duplicate entries (Release Drafter sometimes lists the same PR in multiple categories).
   - Re-categorize entries correctly: `feat:` PRs → Features, `chore:`/`fix:` → Maintenance, `deps` bumps → Dependency Updates.
   - Group related items (e.g. all packaging formats together with install commands, all dep bumps together).
   - Use clear section headers with emoji (📦 🚀 🧰 ⬆️ 🐛 etc.) and concise bullet text.
   - End with `**Full Changelog**: https://github.com/{owner}/{repo}/compare/vX.Y.Z...vA.B.C`
3. **Update and publish** via `gh api … --method PATCH --field draft=false --field tag_name=vX.Y.Z --field make_latest=true`.
4. **Verify** the CI release workflow triggered successfully (`gh run list`).
