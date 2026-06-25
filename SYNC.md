# Upstream sync — review skill

The skills in `skills/review-standards/` and `skills/review-spec/` are **adapted** from
Matt Pocock's `review` skill. The unmodified upstream copy is vendored at
`skills/_upstream/review.SKILL.md` for diffing.

| | |
|---|---|
| Upstream | https://github.com/mattpocock/skills/blob/main/skills/in-progress/review/SKILL.md |
| Raw | https://raw.githubusercontent.com/mattpocock/skills/main/skills/in-progress/review/SKILL.md |
| Vendored at commit | `df129fcfce610712a737fe4bb9362e621f0752c5` |
| Commit date | 2026-06-17 |
| Pulled | 2026-06-25 |

> Note: upstream lives under `skills/in-progress/` — it is explicitly unstable and may
> change or move. Re-pull deliberately, don't auto-fetch in CI.

## What we changed and why

The upstream skill assumes a harness with **sub-agents** (it spawns two parallel
`Agent` calls). **pi has no sub-agents** — built-in tools are only
`read, bash, edit, write, grep, find, ls`. So the two-axis fan-out was moved up to
the GitHub Actions layer:

- `review-standards` and `review-spec` are **single-axis** skills, each run as its own
  pi process, in parallel, by `scripts/review.sh`.
- Each is **non-interactive**: it never asks the user; the fixed point arrives via the
  `REVIEW_BASE` env var instead of a prompt.
- Issue lookup uses `gh` (authenticated by `GITHUB_TOKEN`) instead of a project-specific
  `docs/agents/issue-tracker.md` workflow.
- A third skill, `summarize`, does a **format-only** merge with a TL;DR (the upstream
  "Aggregate" step), running on the cheaper `glm-4.7-flash`.

## How to re-sync

1. Pull the latest upstream raw file; overwrite `skills/_upstream/review.SKILL.md`.
2. `git diff` it against the previous vendored version to see what changed.
3. Port any meaningful changes into the two single-axis skills + `summarize`.
4. Update the commit SHA / dates in the table above.
