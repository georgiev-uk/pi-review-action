#!/usr/bin/env bash
# Orchestrate the two-axis pi review against Cloudflare Workers AI.
#
# Required env:
#   CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_API_TOKEN  Workers AI access
#   REVIEW_BASE                                  diff fixed point (git ref)
#   ACTION_PATH                                  dir containing skills/ + config/
#   GH_TOKEN (or GITHUB_TOKEN), GITHUB_REPOSITORY
# Optional env:
#   MAX_DIFF_LINES       default 20000
#   PR_NUMBER            enables PR comment + incremental re-review tracking
#   HEAD_SHA             PR head sha this run reviews (defaults to git HEAD)
#   MODEL_REVIEWER       default @cf/moonshotai/kimi-k2.7-code
#   MODEL_SUMMARIZER     default @cf/google/gemma-4-26b-a4b-it
#   GITHUB_STEP_SUMMARY  written to if set
set -euo pipefail

: "${CLOUDFLARE_ACCOUNT_ID:?required}"
: "${CLOUDFLARE_API_TOKEN:?required}"
: "${REVIEW_BASE:?required}"
: "${ACTION_PATH:?required}"
export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

MAX_DIFF_LINES="${MAX_DIFF_LINES:-20000}"
MODEL_REVIEWER="${MODEL_REVIEWER:-@cf/moonshotai/kimi-k2.7-code}"
MODEL_SUMMARIZER="${MODEL_SUMMARIZER:-@cf/google/gemma-4-26b-a4b-it}"   # unused: the reviewer writes the final comment directly
REVIEW_TOOLS="read"   # capped escape hatch only — context is inlined; no bash/find/grep exploration

# The head sha this run reviews. Prefer the PR head sha (stable across runs and
# an ancestor of future heads) over `git rev-parse HEAD` (the merge ref, which
# changes every run and can't be diffed-from next time).
HEAD_SHA="${HEAD_SHA:-$(git rev-parse HEAD)}"
export REVIEWED_SHA="$HEAD_SHA"   # embedded in the posted comment's marker

RUN_START=$SECONDS
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Skip pi.dev version/update checks on every pi invocation (2 reviewers +
# summarizer = 3 per review). Pure startup latency; the Workers AI model calls
# are unaffected.
export PI_OFFLINE=1
export PI_SKIP_VERSION_CHECK=1

# --- pi provider config ----------------------------------------------------
# envsubst ONLY the account id; leave $CLOUDFLARE_API_TOKEN for pi to resolve
# at request time (so the token never lands on disk).
mkdir -p "$HOME/.pi/agent"
envsubst '${CLOUDFLARE_ACCOUNT_ID}' \
  < "$ACTION_PATH/config/models.json.tmpl" \
  > "$HOME/.pi/agent/models.json"

# Log the toolchain for traceability (no secrets — token is never printed).
echo "pi $(pi --version 2>/dev/null) · reviewer=${MODEL_REVIEWER} (thinking=low, tools=${REVIEW_TOOLS})"

# --- resolve / fetch the base ----------------------------------------------
if ! git rev-parse --verify "${REVIEW_BASE}^{commit}" >/dev/null 2>&1; then
  echo "Base '${REVIEW_BASE}' not present locally; fetching…"
  git fetch --no-tags --depth=200 origin "${REVIEW_BASE}" >/dev/null 2>&1 || true
  git rev-parse --verify "${REVIEW_BASE}^{commit}" >/dev/null 2>&1 \
    || { echo "::error::Cannot resolve base ref '${REVIEW_BASE}'. Checkout with fetch-depth: 0."; exit 1; }
fi

# --- incremental vs full: has this PR already been reviewed? ----------------
# Find our newest prior comment (marker: pi-review-action:review reviewed=<sha>).
# If that sha == current head, nothing new — skip. If it is an ancestor of HEAD,
# review only the commits since then and feed the prior review in as context.
MARKER_PREFIX="<!-- pi-review-action:review"
MODE="full"
PRIOR_REVIEW=""   # path to the prior review body, when incremental

if [[ -n "${PR_NUMBER:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
  # Stream the IDs of our prior review comments, oldest→newest (ids are integers,
  # so newline-splitting is safe even though comment bodies contain newlines).
  # --paginate runs --jq per page, so a "| last" here would only see one page —
  # take the last id across all pages instead.
  gh api --paginate "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" \
    --jq ".[] | select(.body | contains(\"${MARKER_PREFIX}\")) | .id" \
    > "$WORK/prior-ids" 2>/dev/null || true
  LAST_ID="$(tail -n1 "$WORK/prior-ids" 2>/dev/null || true)"

  PRIOR_SHA=""
  if [[ -n "$LAST_ID" ]]; then
    gh api "repos/${GITHUB_REPOSITORY}/issues/comments/${LAST_ID}" \
      --jq '.body' > "$WORK/prior.md" 2>/dev/null || true
    PRIOR_SHA="$(grep -oE 'reviewed=[0-9a-fA-F]+' "$WORK/prior.md" | head -n1 | cut -d= -f2 || true)"
  fi

  if [[ -n "$PRIOR_SHA" ]]; then
    if [[ "$PRIOR_SHA" == "$HEAD_SHA" ]]; then
      echo "Head ${HEAD_SHA} already reviewed; no new commits. Skipping."
      exit 0
    fi
    # Make sure the prior sha is present locally before ancestor-testing it.
    git rev-parse --verify "${PRIOR_SHA}^{commit}" >/dev/null 2>&1 \
      || git fetch --no-tags --depth=200 origin "$PRIOR_SHA" >/dev/null 2>&1 || true

    if git rev-parse --verify "${PRIOR_SHA}^{commit}" >/dev/null 2>&1 \
       && git merge-base --is-ancestor "$PRIOR_SHA" HEAD 2>/dev/null; then
      MODE="incremental"
      REVIEW_BASE="$PRIOR_SHA"           # reviewers now diff only the new commits
      PRIOR_REVIEW="$WORK/prior.md"
      echo "Incremental review: new commits since previously-reviewed ${PRIOR_SHA}"
    else
      echo "::warning::previously-reviewed sha ${PRIOR_SHA} is not an ancestor of HEAD (rebase/force-push?); reviewing the full diff"
    fi
  fi
fi

post_and_exit() {  # $1 = body file, $2 = exit code
  bash "$ACTION_PATH/scripts/post-comment.sh" "$1" || true
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then cat "$1" >> "$GITHUB_STEP_SUMMARY"; fi
  exit "${2:-0}"
}

# --- guardrail -------------------------------------------------------------
SIZE="$(bash "$ACTION_PATH/scripts/diff-size.sh" "$REVIEW_BASE")"
echo "diff size: ${SIZE} changed lines (limit ${MAX_DIFF_LINES})"
if (( SIZE > MAX_DIFF_LINES )); then
  cat > "$WORK/skip.md" <<EOF
## 🤖 Code review (skipped)

Diff is **${SIZE}** changed lines, over the \`max_diff_lines\` limit of **${MAX_DIFF_LINES}**. Review skipped to bound cost. Raise the limit or split the PR.
EOF
  post_and_exit "$WORK/skip.md" 0
fi

# --- precompute the review context -----------------------------------------
# Previously each reviewer fetched its own context through 20+ agentic tool
# calls (git diff, find, read×13…), and every turn re-sent a reasoning-bloated
# transcript — 400k+ input tokens to review an 80-line diff, ~$1 and ~10 min.
# Compute the context ONCE in shell and inline it, so each axis is essentially a
# single model turn: input collapses to ~diff+files (10-15k tokens).
CTX="$WORK/context"
mkdir -p "$CTX"

# Shared: the diff and the commit log.
git diff "$REVIEW_BASE...HEAD" > "$CTX/diff.patch" 2>/dev/null || true
git log  "$REVIEW_BASE..HEAD" --oneline > "$CTX/commits.txt" 2>/dev/null || true

# Full contents of the changed (non-deleted) files, so the reviewer sees the
# code around each hunk without reading the repo. Bounded: very large files are
# omitted (the diff hunks still carry the actual change).
: > "$CTX/changed-files.md"
while IFS= read -r f; do
  [[ -f "$f" ]] || continue                       # skip deletes / renamed-away
  lines=$(wc -l < "$f" 2>/dev/null || echo 0)
  if (( lines > 800 )); then
    printf '### %s\n\n_(%s lines — omitted to bound input; see the diff hunks)_\n\n' "$f" "$lines" >> "$CTX/changed-files.md"
  else
    { printf '### %s\n\n```\n' "$f"; cat "$f"; printf '\n```\n\n'; } >> "$CTX/changed-files.md"
  fi
done < <(git diff --name-only --diff-filter=d "$REVIEW_BASE...HEAD" 2>/dev/null || true)
[[ -s "$CTX/changed-files.md" ]] || printf '_No file contents available._\n' > "$CTX/changed-files.md"

# Standards axis: the repo's own standards docs.
: > "$CTX/standards-sources.md"
for s in CLAUDE.md AGENTS.md CONTRIBUTING.md CODING_STANDARDS.md CONVENTIONS.md .editorconfig; do
  [[ -f "$s" ]] || continue
  { printf '### %s\n\n```\n' "$s"; cat "$s"; printf '\n```\n\n'; } >> "$CTX/standards-sources.md"
done
[[ -s "$CTX/standards-sources.md" ]] || printf '_No standards docs found in the repo root — review against widely-accepted conventions for the languages in the diff._\n' > "$CTX/standards-sources.md"

# Spec axis: the PR body plus any issues referenced from commits / PR body.
: > "$CTX/spec-sources.md"
if [[ -n "${GH_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
  if [[ -n "${PR_NUMBER:-}" ]]; then
    { echo "### Pull request #${PR_NUMBER}"; echo;
      gh pr view "$PR_NUMBER" --json title,body \
        --jq '"**" + .title + "**\n\n" + (.body // "_(no description)_")' 2>/dev/null; echo; } >> "$CTX/spec-sources.md" || true
  fi
  refs="$( { git log "$REVIEW_BASE..HEAD" --format=%B 2>/dev/null; cat "$CTX/spec-sources.md"; } \
             | grep -oiE '#[0-9]+' | tr -d '#' | sort -un || true)"
  for n in $refs; do
    { echo "### Issue #${n}"; echo;
      gh issue view "$n" --json title,body \
        --jq '"**" + .title + "**\n\n" + (.body // "_(no body)_")' 2>/dev/null; echo; } >> "$CTX/spec-sources.md" || true
  done
fi
[[ -s "$CTX/spec-sources.md" ]] || printf '_No spec source (issue / PRD / PR body) found — if nothing is found, skip the spec axis._\n' > "$CTX/spec-sources.md"

# --- stage 1: two single-axis reviewers, parallel --------------------------
export REVIEW_BASE   # still exported for the read-tool escape hatch's context

# Incremental context: attach the prior review and tell the reviewer that the
# diff now contains ONLY the new commits since that review.
INCR_NOTE=""
PRIOR_ARGS=()
if [[ "$MODE" == "incremental" && -n "$PRIOR_REVIEW" ]]; then
  INCR_NOTE="This is an INCREMENTAL review: REVIEW_BASE is the previously-reviewed commit, so the diff contains ONLY the new commits pushed since the last review. Your earlier review is attached as the first argument — do NOT repeat findings that are unchanged; discuss only the new diff, and explicitly note where the new changes address or newly break a point from your prior review."
  PRIOR_ARGS=("@$PRIOR_REVIEW")
fi

# One Kimi call does BOTH axes (standards + spec) AND writes the final comment
# directly — no second reviewer, no separate summarizer. All context is inlined
# (diff, commits, changed files, standards docs, spec sources), so it runs in
# ~one turn. `read` is the only tool: a capped escape hatch for the rare
# cross-file lookup, with no bash/find/grep to drive repo-wide wandering.
# --mode json gives the event stream we mine for stats; the report is extracted
# from the last assistant message. rc is captured with `|| rc=$?` so `set -e`
# doesn't abort before we record it.
REVIEW_START=$SECONDS
out="$WORK/final.md"
rc=0
for attempt in 1 2 3; do
  rc=0
  pi --mode json -a --no-session \
     --provider cloudflare --model "$MODEL_REVIEWER" \
     --thinking low \
     --tools "$REVIEW_TOOLS" \
     --skill "$ACTION_PATH/skills/review" \
     "@$CTX/diff.patch" "@$CTX/commits.txt" "@$CTX/changed-files.md" \
     "@$CTX/standards-sources.md" "@$CTX/spec-sources.md" \
     ${PRIOR_ARGS[@]+"${PRIOR_ARGS[@]}"} \
     "All context is attached inline: the diff, commit log, full changed files, the repo's standards docs, and the spec sources. Everything you need is here — do NOT explore the repo (read is capped: at most 3 reads, only for a specific unchanged file you must see). Review BOTH axes and print ONLY the final Markdown comment per the review skill. ${INCR_NOTE}" \
     > "${out}.jsonl" 2> "${out}.log" || rc=$?
  if [[ "$rc" == "0" && -s "${out}.jsonl" ]]; then
    jq -rn '[inputs] | map(select(.type=="message_end" and .message.role=="assistant")) | last | (.message.content // [] | map(select(.type=="text") | .text) | join(""))' \
      < "${out}.jsonl" > "$out" 2>/dev/null || true
  fi
  # Success only if extraction produced real (non-whitespace) Markdown — an
  # empty jq result still writes a lone newline, which -s would misread.
  if [[ "$rc" == "0" ]] && grep -q '[^[:space:]]' "$out" 2>/dev/null; then break; fi
  if (( attempt < 3 )); then
    backoff=$(( attempt * 20 + RANDOM % 10 ))
    echo "::warning::review attempt $attempt failed (rc=$rc); retrying in ${backoff}s"
    sleep "$backoff"
  fi
done
grep -q '[^[:space:]]' "$out" 2>/dev/null || : > "$out"

# Instrumentation: where the wall-time / tokens actually went.
STATS=""
[[ -s "${out}.jsonl" ]] && STATS="$(jq -rn -f "$ACTION_PATH/scripts/pi-stats.jq" < "${out}.jsonl" 2>/dev/null || true)"
echo "::notice::review took $((SECONDS - REVIEW_START))s · ${STATS:-no stats}"

if [[ "$rc" != "0" ]]; then
  echo "::warning::reviewer exited with rc=$rc"
  echo "::group::reviewer stderr (pi)"; cat "${out}.log" 2>/dev/null; echo "::endgroup::"
fi

# Fallback comment if the model produced nothing usable after retries.
if ! grep -q '[^[:space:]]' "$out" 2>/dev/null; then
  echo "::warning::reviewer produced no output; posting a failure notice"
  {
    echo "## 🤖 Code review"
    echo
    echo "_Review unavailable — the model returned no output after retries. See the action logs._"
    echo
    echo "---"
    echo "<sub>Two-axis review (Standards + Spec) via the pi harness on Cloudflare Workers AI. Advisory only.</sub>"
  } > "$out"
fi

echo "::group::final.md"; cat "$out"; echo "::endgroup::"

# Kimi sometimes wraps its whole reply in a ``` code fence,
# which would render the entire comment as one code block on GitHub. If the
# body is fenced top-and-bottom, unwrap it.
if [[ "$(head -1 "$WORK/final.md")" == '```'* ]] && [[ "$(grep -c '^```' "$WORK/final.md")" -ge 2 ]]; then
  echo "::warning::reviewer wrapped output in a code fence; unwrapping"
  awk '
    NR==1 && /^```/ { next }            # drop leading fence
    { lines[++n] = $0 }
    END {
      last = n
      while (last > 0 && lines[last] == "") last--   # ignore trailing blanks
      for (i = 1; i <= n; i++) {
        if (i == last && lines[i] ~ /^```$/) continue # drop trailing fence
        print lines[i]
      }
    }
  ' "$WORK/final.md" > "$WORK/final.unwrapped.md" && mv "$WORK/final.unwrapped.md" "$WORK/final.md"
fi

# Prepend an incremental banner so the follow-up comment is self-explanatory.
if [[ "$MODE" == "incremental" ]]; then
  {
    printf '> 🔁 **Incremental review** — only the commits since `%s` (previously reviewed). Earlier findings are not repeated.\n\n' "${PRIOR_SHA:0:12}"
    cat "$WORK/final.md"
  } > "$WORK/final.banner.md" && mv "$WORK/final.banner.md" "$WORK/final.md"
fi

echo "::notice::review total (script) took $((SECONDS - RUN_START))s"
post_and_exit "$WORK/final.md" 0
