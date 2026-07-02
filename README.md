# pi-review-action

A GitHub Action that runs a **two-axis code review** on pull requests using the
[pi](https://pi.dev) agent harness against **Cloudflare Workers AI** — reviewing with
`@cf/moonshotai/kimi-k2.7-code` and summarizing with `@cf/google/gemma-4-26b-a4b-it`. Inference runs
on Cloudflare GPUs; prompts and code never go to Moonshot AI or Google.

The review follows two independent axes (adapted from
[Matt Pocock's `review` skill](https://github.com/mattpocock/skills)):

- **Standards** — does the diff follow the repo's documented coding standards?
- **Spec** — does the diff faithfully implement the originating issue / PRD?

It posts a **PR comment** and a job summary. It is **advisory** — findings never fail the job.

**Incremental re-reviews.** Each comment records the head sha it reviewed. On a later push
the action finds its newest prior comment: if that sha is unchanged it skips (nothing new);
if new commits landed it reviews **only the diff since the last review**, feeds its prior
review in as context, and posts a **new** follow-up comment (marked 🔁) that discusses just
the new changes without repeating unchanged findings. If the branch was rebased/force-pushed
so the prior sha is no longer an ancestor of HEAD, it falls back to a full review.

## How it works

```
pull_request ─► resolve base ─► [diff ≤ max_diff_lines?] ──no──► skip + comment
                                        │ yes
                ┌───────────────────────┴───────────────────────┐   (sequential)
   pi: review-standards skill                       pi: review-spec skill
   model @cf/moonshotai/kimi-k2.7-code               model @cf/moonshotai/kimi-k2.7-code
   (own git diff + file/issue lookup via bash/gh)
                └───────────────────────┬───────────────────────┘
                          pi: summarize skill (format-only + TL;DR)
                          model @cf/google/gemma-4-26b-a4b-it
                                        │
                    PR comment + $GITHUB_STEP_SUMMARY
        (full diff, or only new commits since the last review comment)
```

pi has **no sub-agents**, so the two axes run as separate pi processes, one after the
other. They run **sequentially** (not concurrently) to stay under Workers AI's per-model
request-rate limit — two concurrent Kimi K2.7 tool loops trip a 429. The axes stay fully
isolated regardless. See [`SYNC.md`](./SYNC.md) for how this differs from the upstream skill.

## Usage

```yaml
permissions:
  contents: read
  pull-requests: write
  issues: read

jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0          # required: reviewers diff against the base
      - uses: your-org/pi-review-action@v1
        with:
          account_id: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
          api_token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
```

A copy-paste workflow is in [`workflows/example.yml`](./workflows/example.yml) — drop it
into your repo at `.github/workflows/code-review.yml`. (It lives outside `.github/` here
so GitHub doesn't try to run the sample in this repo.)

### Secrets

| Secret | Notes |
|--------|-------|
| `CLOUDFLARE_ACCOUNT_ID` | Your Cloudflare account id (not secret, passed as input for portability). |
| `CLOUDFLARE_API_TOKEN` | API token scoped to **Workers AI: Read**. |

The token is interpolated by pi at request time and never written to disk; only the
account id is substituted into the generated `models.json`.

## Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `account_id` | — (required) | Cloudflare account id. |
| `api_token` | — (required) | Cloudflare Workers AI token. |
| `base` | auto | Override the diff base. Defaults to the PR base branch. |
| `max_diff_lines` | `20000` | Skip the review if the diff exceeds this many changed lines. |
| `pi_version` | `0.80.2` | Pinned pi CLI version. |
| `model_reviewer` | `@cf/moonshotai/kimi-k2.7-code` | Model for the two axis reviewers. |
| `model_summarizer` | `@cf/google/gemma-4-26b-a4b-it` | Model for the format-only summarizer. |
| `github_token` | `${{ github.token }}` | Reads issues, posts the comment. |

## Local smoke test

Before relying on CI, verify pi can drive the Workers AI tool loop:

```bash
export CLOUDFLARE_ACCOUNT_ID=...    # your account id
export CLOUDFLARE_API_TOKEN=...     # Workers AI: Read
bash scripts/smoke.sh
```

It checks: raw endpoint reachability → pi registers the models → **Kimi K2.7 executes a
bash tool call** → Gemma completes a plain prompt.

## Layout

| Path | Purpose |
|------|---------|
| `action.yml` | Composite action: install pi, resolve base, run review. |
| `scripts/review.sh` | Orchestrator: models.json, guardrail, sequential reviewers, summarizer, post. |
| `scripts/diff-size.sh` | Changed-line count for the guardrail. |
| `scripts/post-comment.sh` | Post PR comment, tagging it with the reviewed head sha. |
| `scripts/smoke.sh` | Local pre-flight check against Workers AI. |
| `config/models.json.tmpl` | pi provider config for the two Workers AI models. |
| `skills/review-standards/` · `skills/review-spec/` | Single-axis review skills. |
| `skills/summarize/` | Format-only merge + TL;DR. |
| `skills/_upstream/` | Vendored upstream skill, for diffing. See `SYNC.md`. |

## License

MIT. Skill content adapted from Matt Pocock's skills — see `SYNC.md` and `LICENSE`.
