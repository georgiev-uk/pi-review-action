# pi-review-action

A GitHub Action that runs a **two-axis code review** on pull requests using the
[pi](https://pi.dev) agent harness against **Cloudflare Workers AI** — reviewing with
`@cf/zai-org/glm-5.2` and summarizing with `@cf/zai-org/glm-4.7-flash`. Inference runs
on Cloudflare GPUs; prompts and code never go to z.ai.

The review follows two independent axes (adapted from
[Matt Pocock's `review` skill](https://github.com/mattpocock/skills)):

- **Standards** — does the diff follow the repo's documented coding standards?
- **Spec** — does the diff faithfully implement the originating issue / PRD?

It posts a single **sticky PR comment** (updated in place) and a job summary. It is
**advisory** — findings never fail the job.

## How it works

```
pull_request ─► resolve base ─► [diff ≤ max_diff_lines?] ──no──► skip + comment
                                        │ yes
                ┌───────────────────────┴───────────────────────┐   (sequential)
   pi: review-standards skill                       pi: review-spec skill
   model @cf/zai-org/glm-5.2                         model @cf/zai-org/glm-5.2
   (own git diff + file/issue lookup via bash/gh)
                └───────────────────────┬───────────────────────┘
                          pi: summarize skill (format-only + TL;DR)
                          model @cf/zai-org/glm-4.7-flash
                                        │
                    sticky PR comment + $GITHUB_STEP_SUMMARY
```

pi has **no sub-agents**, so the two axes run as separate pi processes, one after the
other. They run **sequentially** (not concurrently) to stay under Workers AI's per-model
request-rate limit — two concurrent GLM-5.2 tool loops trip a 429. The axes stay fully
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
| `model_reviewer` | `@cf/zai-org/glm-5.2` | Model for the two axis reviewers. |
| `model_summarizer` | `@cf/zai-org/glm-4.7-flash` | Model for the format-only summarizer. |
| `github_token` | `${{ github.token }}` | Reads issues, posts the comment. |

## Local smoke test

Before relying on CI, verify pi can drive the Workers AI tool loop:

```bash
export CLOUDFLARE_ACCOUNT_ID=...    # your account id
export CLOUDFLARE_API_TOKEN=...     # Workers AI: Read
bash scripts/smoke.sh
```

It checks: raw endpoint reachability → pi registers the models → **GLM-5.2 executes a
bash tool call** → flash completes a plain prompt.

## Layout

| Path | Purpose |
|------|---------|
| `action.yml` | Composite action: install pi, resolve base, run review. |
| `scripts/review.sh` | Orchestrator: models.json, guardrail, sequential reviewers, summarizer, post. |
| `scripts/diff-size.sh` | Changed-line count for the guardrail. |
| `scripts/post-comment.sh` | Find-or-update sticky PR comment. |
| `scripts/smoke.sh` | Local pre-flight check against Workers AI. |
| `config/models.json.tmpl` | pi provider config for the two GLM models. |
| `skills/review-standards/` · `skills/review-spec/` | Single-axis review skills. |
| `skills/summarize/` | Format-only merge + TL;DR. |
| `skills/_upstream/` | Vendored upstream skill, for diffing. See `SYNC.md`. |

## License

MIT. Skill content adapted from Matt Pocock's skills — see `SYNC.md` and `LICENSE`.
