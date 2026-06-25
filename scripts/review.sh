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
#   PR_NUMBER            enables sticky PR comment
#   MODEL_REVIEWER       default @cf/zai-org/glm-5.2
#   MODEL_SUMMARIZER     default @cf/zai-org/glm-4.7-flash
#   GITHUB_STEP_SUMMARY  written to if set
set -euo pipefail

: "${CLOUDFLARE_ACCOUNT_ID:?required}"
: "${CLOUDFLARE_API_TOKEN:?required}"
: "${REVIEW_BASE:?required}"
: "${ACTION_PATH:?required}"
export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

MAX_DIFF_LINES="${MAX_DIFF_LINES:-20000}"
MODEL_REVIEWER="${MODEL_REVIEWER:-@cf/zai-org/glm-5.2}"
MODEL_SUMMARIZER="${MODEL_SUMMARIZER:-@cf/zai-org/glm-4.7-flash}"
REVIEW_TOOLS="bash,read,grep,find,ls"   # read-only-ish; no edit/write

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- pi provider config ----------------------------------------------------
# envsubst ONLY the account id; leave $CLOUDFLARE_API_TOKEN for pi to resolve
# at request time (so the token never lands on disk).
mkdir -p "$HOME/.pi/agent"
envsubst '${CLOUDFLARE_ACCOUNT_ID}' \
  < "$ACTION_PATH/config/models.json.tmpl" \
  > "$HOME/.pi/agent/models.json"

# --- resolve / fetch the base ----------------------------------------------
if ! git rev-parse --verify "${REVIEW_BASE}^{commit}" >/dev/null 2>&1; then
  echo "Base '${REVIEW_BASE}' not present locally; fetching…"
  git fetch --no-tags --depth=200 origin "${REVIEW_BASE}" >/dev/null 2>&1 || true
  git rev-parse --verify "${REVIEW_BASE}^{commit}" >/dev/null 2>&1 \
    || { echo "::error::Cannot resolve base ref '${REVIEW_BASE}'. Checkout with fetch-depth: 0."; exit 1; }
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

# --- stage 1: two single-axis reviewers, in parallel -----------------------
export REVIEW_BASE   # visible to the skills' bash tool calls (git diff "$REVIEW_BASE...HEAD")

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
       "REVIEW_BASE=$REVIEW_BASE . Run the ${skill} review now and print only your Markdown section." \
       > "$out" 2> "${out}.log" || rc=$?
    if [[ "$rc" == "0" && -s "$out" ]]; then break; fi
    if (( attempt < 3 )); then
      local backoff=$(( attempt * 20 ))
      echo "::warning::reviewer '$skill' attempt $attempt failed (rc=$rc); retrying in ${backoff}s"
      sleep "$backoff"
    fi
  done
  echo "$rc" > "${out}.rc"
  return 0
}

# Sequential, not parallel: two concurrent GLM-5.2 tool loops burst past Workers
# AI's request-rate limit (observed 429s). Running one axis at a time keeps the
# request rate under the cap. The axes stay fully isolated — separate pi runs.
run_axis review-standards "$WORK/standards.md"
run_axis review-spec "$WORK/spec.md"

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
pi -p --no-session \
   --provider cloudflare --model "$MODEL_SUMMARIZER" \
   --skill "$ACTION_PATH/skills/summarize" \
   "@$WORK/standards.md" "@$WORK/spec.md" \
   "Merge these two axis reports per the review-summarize skill. Format only." \
   > "$WORK/final.md" 2> "$WORK/final.log" || true

# If the summarizer failed, fall back to a deterministic concatenation.
if [[ ! -s "$WORK/final.md" ]]; then
  echo "::warning::summarizer produced no output; using deterministic merge"
  echo "::group::summarizer stderr (pi)"; cat "$WORK/final.log" 2>/dev/null; echo "::endgroup::"
  {
    echo "## 🤖 Code review (GLM 5.2 · pi)"
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

post_and_exit "$WORK/final.md" 0
