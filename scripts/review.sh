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
MODEL_SUMMARIZER="${MODEL_SUMMARIZER:-@cf/google/gemma-4-26b-a4b-it}"
REVIEW_TOOLS="bash,read,grep,find,ls"   # read-only-ish; no edit/write

# The head sha this run reviews. Prefer the PR head sha (stable across runs and
# an ancestor of future heads) over `git rev-parse HEAD` (the merge ref, which
# changes every run and can't be diffed-from next time).
HEAD_SHA="${HEAD_SHA:-$(git rev-parse HEAD)}"
export REVIEWED_SHA="$HEAD_SHA"   # embedded in the posted comment's marker

RUN_START=$SECONDS
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- pi provider config ----------------------------------------------------
# envsubst ONLY the account id; leave $CLOUDFLARE_API_TOKEN for pi to resolve
# at request time (so the token never lands on disk).
mkdir -p "$HOME/.pi/agent"
envsubst '${CLOUDFLARE_ACCOUNT_ID}' \
  < "$ACTION_PATH/config/models.json.tmpl" \
  > "$HOME/.pi/agent/models.json"

# Log the toolchain for traceability (no secrets — token is never printed).
echo "pi $(pi --version 2>/dev/null) · reviewer=${MODEL_REVIEWER} · summarizer=${MODEL_SUMMARIZER}"

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

# --- stage 1: two single-axis reviewers, sequential ------------------------
export REVIEW_BASE   # visible to the skills' bash tool calls (git diff "$REVIEW_BASE...HEAD")

# Incremental context: attach the prior review and tell the reviewer that the
# diff now contains ONLY the new commits since that review.
INCR_NOTE=""
PRIOR_ARGS=()
if [[ "$MODE" == "incremental" && -n "$PRIOR_REVIEW" ]]; then
  INCR_NOTE="This is an INCREMENTAL review: REVIEW_BASE is the previously-reviewed commit, so the diff contains ONLY the new commits pushed since the last review. Your earlier review is attached as the first argument — do NOT repeat findings that are unchanged; discuss only the new diff, and explicitly note where the new changes address or newly break a point from your prior review."
  PRIOR_ARGS=("@$PRIOR_REVIEW")
fi

# One reviewer pass, with retry-on-failure. pi against Workers AI can return
# 429 (rate limit) under load; back off and retry rather than fail the axis.
# rc is captured with `|| rc=$?` so `set -e` doesn't abort before we record it.
run_axis() {  # $1 = skill dir name, $2 = output file
  local skill="$1" out="$2" rc=0 attempt
  for attempt in 1 2 3; do
    rc=0
    pi -p -a --no-session \
       --provider cloudflare --model "$MODEL_REVIEWER" \
       --tools "$REVIEW_TOOLS" \
       --skill "$ACTION_PATH/skills/$skill" \
       ${PRIOR_ARGS[@]+"${PRIOR_ARGS[@]}"} \
       "REVIEW_BASE=$REVIEW_BASE . ${INCR_NOTE} Run the ${skill} review now and print only your Markdown section." \
       > "$out" 2> "${out}.log" || rc=$?
    if [[ "$rc" == "0" && -s "$out" ]]; then break; fi
    if (( attempt < 3 )); then
      # Jitter the backoff so two axes retrying at once don't re-collide.
      local backoff=$(( attempt * 20 + RANDOM % 10 ))
      echo "::warning::reviewer '$skill' attempt $attempt failed (rc=$rc); retrying in ${backoff}s"
      sleep "$backoff"
    fi
  done
  echo "$rc" > "${out}.rc"
  return 0
}

# Parallel: the two axes are fully isolated (separate pi runs), so run them
# concurrently to roughly halve stage-1 wall time. A short stagger + jittered
# retry backoff keep the two Kimi K2.7 loops from bursting Workers AI's
# request-rate limit in lockstep (observed 429s when started simultaneously);
# the per-axis retry-on-429 absorbs any that still slip through.
STAGE1_START=$SECONDS
run_axis review-standards "$WORK/standards.md" &
PID_STANDARDS=$!
sleep 3   # stagger so the two loops don't hit the rate limiter in lockstep
run_axis review-spec "$WORK/spec.md" &
PID_SPEC=$!
wait "$PID_STANDARDS" "$PID_SPEC"
echo "::notice::stage 1 (both axes, parallel) took $((SECONDS - STAGE1_START))s"

# Surface each reviewer's exit code + stderr so CI failures are diagnosable.
for axis in standards spec; do
  rc="$(cat "$WORK/${axis}.md.rc" 2>/dev/null || echo '?')"
  if [[ "$rc" != "0" ]]; then
    echo "::warning::reviewer '$axis' exited with rc=$rc"
    echo "::group::${axis} stderr (pi)"; cat "$WORK/${axis}.md.log" 2>/dev/null; echo "::endgroup::"
  fi
done

# Fallbacks so the summarizer always has both sections.
[[ -s "$WORK/standards.md" ]] || printf '## Standards\n\n_Reviewer produced no output._\n' > "$WORK/standards.md"
[[ -s "$WORK/spec.md" ]]      || printf '## Spec\n\n_Reviewer produced no output._\n'      > "$WORK/spec.md"

echo "::group::standards.md"; cat "$WORK/standards.md"; echo "::endgroup::"
echo "::group::spec.md";      cat "$WORK/spec.md";      echo "::endgroup::"

# --- stage 2: format-only summarizer (flash) -------------------------------
STAGE2_START=$SECONDS
pi -p --no-session \
   --provider cloudflare --model "$MODEL_SUMMARIZER" \
   --skill "$ACTION_PATH/skills/summarize" \
   "@$WORK/standards.md" "@$WORK/spec.md" \
   "Merge these two axis reports per the review-summarize skill. Format only." \
   > "$WORK/final.md" 2> "$WORK/final.log" || true
echo "::notice::stage 2 (summarizer) took $((SECONDS - STAGE2_START))s"

# If the summarizer failed, fall back to a deterministic concatenation.
if [[ ! -s "$WORK/final.md" ]]; then
  echo "::warning::summarizer produced no output; using deterministic merge"
  echo "::group::summarizer stderr (pi)"; cat "$WORK/final.log" 2>/dev/null; echo "::endgroup::"
  {
    echo "## 🤖 Code review (Kimi K2.7 · pi)"
    echo
    echo "_Summarizer unavailable — raw axis reports below._"
    echo
    cat "$WORK/standards.md"
    echo
    cat "$WORK/spec.md"
    echo
    echo "---"
    echo "<sub>Two-axis review via the pi harness on Cloudflare Workers AI. Advisory only.</sub>"
  } > "$WORK/final.md"
fi

# The summarizer (flash) sometimes wraps its whole reply in a ``` code fence,
# which would render the entire comment as one code block on GitHub. If the
# body is fenced top-and-bottom, unwrap it.
if [[ "$(head -1 "$WORK/final.md")" == '```'* ]] && [[ "$(grep -c '^```' "$WORK/final.md")" -ge 2 ]]; then
  echo "::warning::summarizer wrapped output in a code fence; unwrapping"
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
